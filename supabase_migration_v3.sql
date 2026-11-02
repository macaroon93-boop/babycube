-- 이유식 큐브 앱 v3.0 추가 마이그레이션
-- 기존 cubes / cube_usage / meal_entries / meal_entry_items 데이터는 보존합니다.
-- Supabase SQL Editor에서 전체 내용을 한 번 실행하세요.

-- 식단은 큐브 개수 단위로 기록하고, 실제 사용 중량은 큐브별 기준 중량으로 계산합니다.
alter table public.meal_entry_items
  add column if not exists used_qty numeric(10,2) not null default 1;
update public.meal_entry_items i
set used_qty=round((i.used_g / coalesce(nullif(c.weight,0),20))::numeric,2)
from public.cubes c where c.id=i.cube_id;

-- 사용기록의 원천을 구분합니다.
-- legacy: v3 이전 기록(출처가 불명확하므로 삭제 시 재고를 임의 복원하지 않음)
-- manual: 재고 화면에서 직접 차감한 1개 사용
-- meal: 식단에 등록하면서 차감한 큐브 사용
alter table public.cube_usage
  add column if not exists usage_type text not null default 'legacy';
alter table public.cube_usage
  add column if not exists used_qty numeric(10,2) not null default 1;
alter table public.cube_usage
  add column if not exists meal_item_id uuid references public.meal_entry_items(id) on delete cascade;

create table if not exists public.family_messages (
  id uuid primary key default gen_random_uuid(),
  author text not null check (author in ('아빠','엄마')),
  message varchar(100) not null check (char_length(trim(message)) between 1 and 100),
  created_at timestamptz not null default now()
);

alter table public.family_messages enable row level security;
drop policy if exists "authenticated users manage family messages" on public.family_messages;
create policy "authenticated users manage family messages" on public.family_messages
for all to authenticated using (true) with check (true);

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='family_messages') then
    alter publication supabase_realtime add table public.family_messages;
  end if;
end $$;

-- 재고 화면에서 1개 사용: 재고 차감과 사용기록을 하나의 트랜잭션으로 처리
create or replace function public.record_manual_baby_cube_use(p_cube_id uuid)
returns void language plpgsql security invoker set search_path=public as $$
declare v_cube public.cubes%rowtype;
begin
  select * into v_cube from public.cubes where id=p_cube_id for update;
  if not found then raise exception 'Cube not found'; end if;
  if v_cube.qty < 1 then raise exception '사용 가능한 큐브가 부족합니다.'; end if;
  update public.cubes set qty=qty-1,updated_at=now() where id=p_cube_id;
  insert into public.cube_usage(name,cube_id,used_at,usage_type,used_qty)
  values(v_cube.name,v_cube.id,now(),'manual',1);
end; $$;

-- 식단 저장/수정: 사용 개수 × 큐브 1개 중량으로 재고 차감
create or replace function public.save_baby_meal(
  p_date date, p_slot text, p_actual_intake_g numeric, p_note text, p_items jsonb
) returns void language plpgsql security invoker set search_path=public as $$
declare
  v_meal_id uuid;
  v_item record;
  v_cube public.cubes%rowtype;
  v_old record;
  v_meal_item_id uuid;
  v_used_g numeric;
begin
  if p_slot not in ('아침','점심','저녁') then raise exception 'Invalid meal slot'; end if;
  if p_actual_intake_g is null or p_actual_intake_g < 0 then raise exception 'Invalid intake amount'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then raise exception 'At least one cube item is required'; end if;

  select id into v_meal_id from public.meal_entries where meal_date=p_date and meal_slot=p_slot for update;
  if v_meal_id is not null then
    for v_old in
      select cube_id,sum(used_qty) as used_qty
      from public.meal_entry_items where meal_id=v_meal_id and cube_id is not null group by cube_id
    loop
      update public.cubes set qty=round((qty+v_old.used_qty)::numeric,2),updated_at=now() where id=v_old.cube_id;
    end loop;
    -- 연결된 기존 사용기록은 meal_item_id의 FK cascade로 함께 제거됩니다.
    delete from public.meal_entry_items where meal_id=v_meal_id;
    update public.meal_entries set actual_intake_g=p_actual_intake_g,note=p_note,updated_at=now() where id=v_meal_id;
  else
    insert into public.meal_entries(meal_date,meal_slot,actual_intake_g,note)
    values(p_date,p_slot,p_actual_intake_g,p_note) returning id into v_meal_id;
  end if;

  for v_item in select * from jsonb_to_recordset(p_items) as x(cube_id uuid,cube_name text,used_qty numeric) loop
    if v_item.used_qty is null or v_item.used_qty<=0 or v_item.used_qty<>trunc(v_item.used_qty) then
      raise exception '사용 개수는 1 이상의 정수여야 합니다.';
    end if;
    select * into v_cube from public.cubes where id=v_item.cube_id for update;
    if not found then raise exception 'Cube not found: %',v_item.cube_id; end if;
    v_used_g := v_item.used_qty * v_cube.weight;
    if v_cube.qty < v_item.used_qty then
      raise exception '재고 부족: % (남은 개수 %, 요청 개수 %)',v_cube.name,v_cube.qty,v_item.used_qty;
    end if;
    update public.cubes set qty=round((qty-v_item.used_qty)::numeric,2),updated_at=now() where id=v_item.cube_id;
    insert into public.meal_entry_items(meal_id,cube_id,cube_name,used_g,used_qty)
    values(v_meal_id,v_cube.id,v_cube.name,v_used_g,v_item.used_qty) returning id into v_meal_item_id;
    insert into public.cube_usage(name,cube_id,used_at,usage_type,used_qty,meal_item_id)
    values(v_cube.name,v_cube.id,now(),'meal',v_item.used_qty,v_meal_item_id);
  end loop;
end; $$;

-- 사용기록 삭제: v3 이후 기록은 재고를 복원하고, 식단 연결 기록은 해당 재료 항목도 제거
-- legacy 기록은 원래 사용 경로를 확정할 수 없어 기록만 삭제합니다.
create or replace function public.delete_baby_cube_usage(p_usage_id uuid)
returns void language plpgsql security invoker set search_path=public as $$
declare
  v_usage public.cube_usage%rowtype;
  v_item public.meal_entry_items%rowtype;
begin
  select * into v_usage from public.cube_usage where id=p_usage_id for update;
  if not found then raise exception 'Usage record not found'; end if;

  if v_usage.usage_type='manual' then
    update public.cubes set qty=qty+coalesce(v_usage.used_qty,1),updated_at=now() where id=v_usage.cube_id;
  elsif v_usage.usage_type='meal' and v_usage.meal_item_id is not null then
    select * into v_item from public.meal_entry_items where id=v_usage.meal_item_id for update;
    if found and v_item.cube_id is not null then
      update public.cubes set qty=qty+coalesce(v_item.used_qty,v_usage.used_qty,1),updated_at=now() where id=v_item.cube_id;
    end if;
    delete from public.meal_entry_items where id=v_usage.meal_item_id;
    -- FK cascade로 해당 cube_usage 행도 삭제됩니다.
    return;
  end if;

  delete from public.cube_usage where id=p_usage_id;
end; $$;

-- 식단 삭제: 식단 재료 사용량을 재고로 복원합니다. 연결된 사용기록은 FK cascade로 삭제됩니다.
create or replace function public.delete_baby_meal(p_meal_id uuid)
returns void language plpgsql security invoker set search_path=public as $$
declare v_old record;
begin
  for v_old in
    select cube_id,sum(used_qty) as used_qty
    from public.meal_entry_items where meal_id=p_meal_id and cube_id is not null group by cube_id
  loop
    update public.cubes set qty=round((qty+v_old.used_qty)::numeric,2),updated_at=now() where id=v_old.cube_id;
  end loop;
  delete from public.meal_entries where id=p_meal_id;
end; $$;

-- 백업 복원: v2 백업도 읽을 수 있고, v3 백업은 가족 한마디와 사용기록 연결정보까지 복원합니다.
create or replace function public.restore_baby_cube_backup(p_backup jsonb)
returns void language plpgsql security invoker set search_path=public as $$
begin
  if jsonb_typeof(p_backup->'items')<>'array' or jsonb_typeof(p_backup->'history')<>'array'
     or jsonb_typeof(p_backup->'meals')<>'array' or jsonb_typeof(p_backup->'mealItems')<>'array' then
    raise exception 'Invalid backup file structure';
  end if;
  if (p_backup ? 'familyMessages') and jsonb_typeof(p_backup->'familyMessages')<>'array' then
    raise exception 'Invalid family messages backup';
  end if;

  delete from public.cube_usage;
  delete from public.meal_entry_items;
  delete from public.meal_entries;
  delete from public.cubes;

  insert into public.cubes(id,name,category,qty,weight,made,expiry,created_at,updated_at)
  select id,name,coalesce(category,'기타'),qty,coalesce(weight,20),made,expiry,coalesce(created_at,now()),coalesce(updated_at,now())
  from jsonb_to_recordset(p_backup->'items') as x(id uuid,name text,category text,qty numeric,weight numeric,made date,expiry date,created_at timestamptz,updated_at timestamptz);

  insert into public.meal_entries(id,meal_date,meal_slot,actual_intake_g,note,created_at,updated_at)
  select id,meal_date,meal_slot,actual_intake_g,note,coalesce(created_at,now()),coalesce(updated_at,now())
  from jsonb_to_recordset(p_backup->'meals') as x(id uuid,meal_date date,meal_slot text,actual_intake_g numeric,note text,created_at timestamptz,updated_at timestamptz);

  insert into public.meal_entry_items(id,meal_id,cube_id,cube_name,used_g,used_qty,created_at)
  select x.id,x.meal_id,x.cube_id,x.cube_name,x.used_g,
         coalesce(x.used_qty,case when c.weight is not null and c.weight>0 then x.used_g/c.weight else 1 end),
         coalesce(x.created_at,now())
  from jsonb_to_recordset(p_backup->'mealItems') as x(id uuid,meal_id uuid,cube_id uuid,cube_name text,used_g numeric,used_qty numeric,created_at timestamptz)
  left join public.cubes c on c.id=x.cube_id;

  insert into public.cube_usage(id,name,cube_id,used_at,usage_type,used_qty,meal_item_id)
  select id,name,cube_id,used_at,coalesce(usage_type,'legacy'),coalesce(used_qty,1),meal_item_id
  from jsonb_to_recordset(p_backup->'history') as x(id uuid,name text,cube_id uuid,used_at timestamptz,usage_type text,used_qty numeric,meal_item_id uuid);

  -- v2 백업에는 familyMessages가 없으므로 기존 가족 한마디를 보존합니다.
  if p_backup ? 'familyMessages' then
    delete from public.family_messages;
    insert into public.family_messages(id,author,message,created_at)
    select id,author,message,coalesce(created_at,now())
    from jsonb_to_recordset(p_backup->'familyMessages') as x(id uuid,author text,message text,created_at timestamptz);
  end if;
end; $$;

revoke all on function public.record_manual_baby_cube_use(uuid) from public, anon;
revoke all on function public.save_baby_meal(date,text,numeric,text,jsonb) from public, anon;
revoke all on function public.delete_baby_cube_usage(uuid) from public, anon;
revoke all on function public.delete_baby_meal(uuid) from public, anon;
revoke all on function public.restore_baby_cube_backup(jsonb) from public, anon;
grant execute on function public.record_manual_baby_cube_use(uuid) to authenticated;
grant execute on function public.save_baby_meal(date,text,numeric,text,jsonb) to authenticated;
grant execute on function public.delete_baby_cube_usage(uuid) to authenticated;
grant execute on function public.delete_baby_meal(uuid) to authenticated;
grant execute on function public.restore_baby_cube_backup(jsonb) to authenticated;
