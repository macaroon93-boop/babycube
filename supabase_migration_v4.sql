-- 이유식 큐브 매니저 v3.2 추가 마이그레이션
-- v2/v3 마이그레이션을 이미 적용한 프로젝트에서 1회 실행합니다.
-- 기존 데이터/테이블을 삭제하지 않습니다. 기존 재고는 모두 냉동 수량으로 간주합니다.

-- 냉동/해동 수량 분리. 기존 qty는 냉동 수량으로 유지하고 thawed_qty를 추가합니다.
alter table public.cubes
  add column if not exists thawed_qty numeric(10,2) not null default 0;

-- 재고 사용 시 해동 큐브를 먼저 소비하고, 삭제/복원 시 원래 상태를 복구합니다.
alter table public.cube_usage
  add column if not exists used_thawed_qty numeric(10,2) not null default 0;
alter table public.meal_entry_items
  add column if not exists reaction text not null default '미기록';
alter table public.meal_entry_items
  add column if not exists used_thawed_qty numeric(10,2) not null default 0;

-- 해동/폐기 이력
create table if not exists public.cube_events (
  id uuid primary key default gen_random_uuid(),
  cube_id uuid references public.cubes(id) on delete set null,
  cube_name text not null,
  event_type text not null check (event_type in ('thaw','discard')),
  qty numeric(10,2) not null check (qty > 0),
  used_thawed_qty numeric(10,2) not null default 0,
  note text,
  event_at timestamptz not null default now()
);
alter table public.cube_events add column if not exists used_thawed_qty numeric(10,2) not null default 0;
alter table public.cube_events enable row level security;
drop policy if exists "authenticated users manage cube events" on public.cube_events;
create policy "authenticated users manage cube events" on public.cube_events
for all to authenticated using (true) with check (true);

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='cube_events') then
    alter publication supabase_realtime add table public.cube_events;
  end if;
end $$;

-- 냉동 큐브 1개를 해동 우선 사용 처리합니다.
create or replace function public.record_manual_baby_cube_use_v4(p_cube_id uuid)
returns void language plpgsql security invoker set search_path=public as $$
declare v_cube public.cubes%rowtype; v_thawed numeric := 0;
begin
  select * into v_cube from public.cubes where id=p_cube_id for update;
  if not found then raise exception 'Cube not found'; end if;
  if coalesce(v_cube.qty,0)+coalesce(v_cube.thawed_qty,0)<1 then raise exception '사용 가능한 큐브가 부족합니다.'; end if;
  if coalesce(v_cube.thawed_qty,0)>=1 then
    v_thawed := 1;
    update public.cubes set thawed_qty=thawed_qty-1,updated_at=now() where id=p_cube_id;
  else
    update public.cubes set qty=qty-1,updated_at=now() where id=p_cube_id;
  end if;
  insert into public.cube_usage(name,cube_id,used_at,usage_type,used_qty,used_thawed_qty)
  values(v_cube.name,v_cube.id,now(),'manual',1,v_thawed);
end; $$;

-- 해동은 냉동 수량에서 해동 수량으로 이동, 폐기는 해동 수량부터 차감합니다.
create or replace function public.record_baby_cube_event_v4(
  p_cube_id uuid, p_event_type text, p_qty numeric, p_note text default null
) returns void language plpgsql security invoker set search_path=public as $$
declare v_cube public.cubes%rowtype; v_thawed_used numeric := 0; v_frozen_used numeric := 0;
begin
  if p_event_type not in ('thaw','discard') then raise exception 'Invalid event type'; end if;
  if p_qty is null or p_qty<=0 or p_qty<>trunc(p_qty) then raise exception '개수는 1 이상의 정수여야 합니다.'; end if;
  select * into v_cube from public.cubes where id=p_cube_id for update;
  if not found then raise exception 'Cube not found'; end if;
  if p_event_type='thaw' then
    if coalesce(v_cube.qty,0)<p_qty then raise exception '냉동 큐브 수량이 부족합니다.'; end if;
    update public.cubes set qty=qty-p_qty,thawed_qty=thawed_qty+p_qty,updated_at=now() where id=p_cube_id;
  else
    if coalesce(v_cube.qty,0)+coalesce(v_cube.thawed_qty,0)<p_qty then raise exception '보유 수량이 부족합니다.'; end if;
    v_thawed_used := least(coalesce(v_cube.thawed_qty,0),p_qty);
    v_frozen_used := p_qty-v_thawed_used;
    update public.cubes set qty=qty-v_frozen_used,thawed_qty=thawed_qty-v_thawed_used,updated_at=now() where id=p_cube_id;
  end if;
  insert into public.cube_events(cube_id,cube_name,event_type,qty,used_thawed_qty,note)
  values(v_cube.id,v_cube.name,p_event_type,p_qty,v_thawed_used,nullif(trim(p_note),''));
end; $$;

-- 식단 저장: 해동 큐브를 우선 차감하고 재료별 섭취 반응/차감 출처를 저장합니다.
create or replace function public.save_baby_meal_v4(
  p_date date, p_slot text, p_actual_intake_g numeric, p_note text, p_items jsonb
) returns void language plpgsql security invoker set search_path=public as $$
declare
  v_meal_id uuid; v_item record; v_cube public.cubes%rowtype; v_old record;
  v_meal_item_id uuid; v_used_g numeric; v_thawed_used numeric; v_frozen_used numeric;
begin
  if p_slot not in ('아침','점심','저녁') then raise exception 'Invalid meal slot'; end if;
  if p_actual_intake_g is null or p_actual_intake_g<0 then raise exception 'Invalid intake amount'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'At least one cube item is required'; end if;
  select id into v_meal_id from public.meal_entries where meal_date=p_date and meal_slot=p_slot for update;
  if v_meal_id is not null then
    for v_old in select cube_id,sum(used_qty) used_qty,sum(used_thawed_qty) used_thawed_qty
      from public.meal_entry_items where meal_id=v_meal_id and cube_id is not null group by cube_id
    loop
      update public.cubes set qty=qty+(v_old.used_qty-v_old.used_thawed_qty),thawed_qty=thawed_qty+v_old.used_thawed_qty,updated_at=now() where id=v_old.cube_id;
    end loop;
    delete from public.meal_entry_items where meal_id=v_meal_id;
    update public.meal_entries set actual_intake_g=p_actual_intake_g,note=p_note,updated_at=now() where id=v_meal_id;
  else
    insert into public.meal_entries(meal_date,meal_slot,actual_intake_g,note) values(p_date,p_slot,p_actual_intake_g,p_note) returning id into v_meal_id;
  end if;
  for v_item in select * from jsonb_to_recordset(p_items) as x(cube_id uuid,cube_name text,used_qty numeric,reaction text) loop
    if v_item.used_qty is null or v_item.used_qty<=0 or v_item.used_qty<>trunc(v_item.used_qty) then raise exception '사용 개수는 1 이상의 정수여야 합니다.'; end if;
    select * into v_cube from public.cubes where id=v_item.cube_id for update;
    if not found then raise exception 'Cube not found: %',v_item.cube_id; end if;
    if coalesce(v_cube.qty,0)+coalesce(v_cube.thawed_qty,0)<v_item.used_qty then raise exception '재고 부족: % (남은 개수 %, 요청 개수 %)',v_cube.name,coalesce(v_cube.qty,0)+coalesce(v_cube.thawed_qty,0),v_item.used_qty; end if;
    v_thawed_used := least(coalesce(v_cube.thawed_qty,0),v_item.used_qty);
    v_frozen_used := v_item.used_qty-v_thawed_used;
    v_used_g := v_item.used_qty*v_cube.weight;
    update public.cubes set qty=qty-v_frozen_used,thawed_qty=thawed_qty-v_thawed_used,updated_at=now() where id=v_item.cube_id;
    insert into public.meal_entry_items(meal_id,cube_id,cube_name,used_g,used_qty,reaction,used_thawed_qty)
    values(v_meal_id,v_cube.id,v_cube.name,v_used_g,v_item.used_qty,coalesce(nullif(v_item.reaction,''),'미기록'),v_thawed_used)
    returning id into v_meal_item_id;
    insert into public.cube_usage(name,cube_id,used_at,usage_type,used_qty,used_thawed_qty,meal_item_id)
    values(v_cube.name,v_cube.id,now(),'meal',v_item.used_qty,v_thawed_used,v_meal_item_id);
  end loop;
end; $$;

-- 사용기록 삭제 시 차감 당시 냉동/해동 상태를 복구합니다.
create or replace function public.delete_baby_cube_usage_v4(p_usage_id uuid)
returns void language plpgsql security invoker set search_path=public as $$
declare v_usage public.cube_usage%rowtype; v_item public.meal_entry_items%rowtype;
begin
  select * into v_usage from public.cube_usage where id=p_usage_id for update;
  if not found then raise exception 'Usage record not found'; end if;
  if v_usage.usage_type='manual' then
    update public.cubes set qty=qty+(coalesce(v_usage.used_qty,1)-coalesce(v_usage.used_thawed_qty,0)),thawed_qty=thawed_qty+coalesce(v_usage.used_thawed_qty,0),updated_at=now() where id=v_usage.cube_id;
  elsif v_usage.usage_type='meal' and v_usage.meal_item_id is not null then
    select * into v_item from public.meal_entry_items where id=v_usage.meal_item_id for update;
    if found and v_item.cube_id is not null then
      update public.cubes set qty=qty+(coalesce(v_item.used_qty,v_usage.used_qty,1)-coalesce(v_item.used_thawed_qty,v_usage.used_thawed_qty,0)),thawed_qty=thawed_qty+coalesce(v_item.used_thawed_qty,v_usage.used_thawed_qty,0),updated_at=now() where id=v_item.cube_id;
    end if;
    delete from public.meal_entry_items where id=v_usage.meal_item_id;
    return;
  end if;
  delete from public.cube_usage where id=p_usage_id;
end; $$;

-- 식단 삭제 시 냉동/해동 수량을 각각 복원합니다.
create or replace function public.delete_baby_meal_v4(p_meal_id uuid)
returns void language plpgsql security invoker set search_path=public as $$
declare v_old record;
begin
  for v_old in select cube_id,sum(used_qty) used_qty,sum(used_thawed_qty) used_thawed_qty
    from public.meal_entry_items where meal_id=p_meal_id and cube_id is not null group by cube_id
  loop
    update public.cubes set qty=qty+(v_old.used_qty-v_old.used_thawed_qty),thawed_qty=thawed_qty+v_old.used_thawed_qty,updated_at=now() where id=v_old.cube_id;
  end loop;
  delete from public.meal_entries where id=p_meal_id;
end; $$;

revoke all on function public.record_manual_baby_cube_use_v4(uuid) from public,anon;
revoke all on function public.record_baby_cube_event_v4(uuid,text,numeric,text) from public,anon;
revoke all on function public.save_baby_meal_v4(date,text,numeric,text,jsonb) from public,anon;
revoke all on function public.delete_baby_cube_usage_v4(uuid) from public,anon;
revoke all on function public.delete_baby_meal_v4(uuid) from public,anon;
grant execute on function public.record_manual_baby_cube_use_v4(uuid) to authenticated;
grant execute on function public.record_baby_cube_event_v4(uuid,text,numeric,text) to authenticated;
grant execute on function public.save_baby_meal_v4(date,text,numeric,text,jsonb) to authenticated;
grant execute on function public.delete_baby_cube_usage_v4(uuid) to authenticated;
grant execute on function public.delete_baby_meal_v4(uuid) to authenticated;
