-- 이유식 큐브 앱 v2 업그레이드
-- 기존 cubes / cube_usage 데이터는 삭제하지 않습니다.
-- Supabase SQL Editor에서 이 파일 전체를 한 번 실행하세요.

-- 부분 사용(예: 20g 큐브에서 10g 사용)을 지원하기 위해 큐브 수량을 소수로 변경
alter table public.cubes alter column qty type numeric(10,2) using qty::numeric(10,2);

create table if not exists public.meal_entries (
  id uuid primary key default gen_random_uuid(),
  meal_date date not null,
  meal_slot text not null check (meal_slot in ('아침','점심','저녁')),
  actual_intake_g numeric(10,2) not null default 0 check (actual_intake_g >= 0),
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(meal_date, meal_slot)
);

create table if not exists public.meal_entry_items (
  id uuid primary key default gen_random_uuid(),
  meal_id uuid not null references public.meal_entries(id) on delete cascade,
  cube_id uuid references public.cubes(id) on delete set null,
  cube_name text not null,
  used_g numeric(10,2) not null check (used_g > 0),
  created_at timestamptz not null default now()
);

alter table public.meal_entries enable row level security;
alter table public.meal_entry_items enable row level security;

drop policy if exists "authenticated users manage meal entries" on public.meal_entries;
create policy "authenticated users manage meal entries" on public.meal_entries
for all to authenticated using (true) with check (true);

drop policy if exists "authenticated users manage meal entry items" on public.meal_entry_items;
create policy "authenticated users manage meal entry items" on public.meal_entry_items
for all to authenticated using (true) with check (true);

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='meal_entries') then
    alter publication supabase_realtime add table public.meal_entries;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='meal_entry_items') then
    alter publication supabase_realtime add table public.meal_entry_items;
  end if;
end $$;

-- 한 끼 식단 저장/수정: 기존 사용량을 재고로 되돌린 뒤 새 사용량을 차감하는 단일 트랜잭션
create or replace function public.save_baby_meal(
  p_date date, p_slot text, p_actual_intake_g numeric, p_note text, p_items jsonb
) returns void language plpgsql security invoker set search_path=public as $$
declare v_meal_id uuid; v_item record; v_cube public.cubes%rowtype; v_old record;
begin
  if p_slot not in ('아침','점심','저녁') then raise exception 'Invalid meal slot'; end if;
  if p_actual_intake_g is null or p_actual_intake_g < 0 then raise exception 'Invalid intake amount'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then raise exception 'At least one cube item is required'; end if;

  select id into v_meal_id from public.meal_entries where meal_date=p_date and meal_slot=p_slot for update;
  if v_meal_id is not null then
    for v_old in select cube_id, sum(used_g) as used_g from public.meal_entry_items where meal_id=v_meal_id and cube_id is not null group by cube_id loop
      update public.cubes set qty=qty+(v_old.used_g/weight), updated_at=now() where id=v_old.cube_id;
    end loop;
    delete from public.meal_entry_items where meal_id=v_meal_id;
    update public.meal_entries set actual_intake_g=p_actual_intake_g,note=p_note,updated_at=now() where id=v_meal_id;
  else
    insert into public.meal_entries(meal_date,meal_slot,actual_intake_g,note) values(p_date,p_slot,p_actual_intake_g,p_note) returning id into v_meal_id;
  end if;

  for v_item in select * from jsonb_to_recordset(p_items) as x(cube_id uuid,cube_name text,used_g numeric) loop
    if v_item.used_g is null or v_item.used_g<=0 then raise exception 'Invalid cube usage amount'; end if;
    select * into v_cube from public.cubes where id=v_item.cube_id for update;
    if not found then raise exception 'Cube not found: %',v_item.cube_id; end if;
    if v_cube.qty*v_cube.weight < v_item.used_g then raise exception '재고 부족: % (남은 양 %, 요청량 %)',v_cube.name,v_cube.qty*v_cube.weight,v_item.used_g; end if;
    update public.cubes set qty=round((qty-(v_item.used_g/weight))::numeric,2),updated_at=now() where id=v_item.cube_id;
    insert into public.meal_entry_items(meal_id,cube_id,cube_name,used_g) values(v_meal_id,v_item.cube_id,v_cube.name,v_item.used_g);
    insert into public.cube_usage(name,cube_id,used_at) values(v_cube.name,v_item.cube_id,now());
  end loop;
end; $$;

-- 식단 삭제: 해당 식단에서 사용했던 큐브 중량을 재고로 복구
create or replace function public.delete_baby_meal(p_meal_id uuid)
returns void language plpgsql security invoker set search_path=public as $$
declare v_old record;
begin
  for v_old in select cube_id,sum(used_g) as used_g from public.meal_entry_items where meal_id=p_meal_id and cube_id is not null group by cube_id loop
    update public.cubes set qty=round((qty+(v_old.used_g/weight))::numeric,2),updated_at=now() where id=v_old.cube_id;
  end loop;
  delete from public.meal_entries where id=p_meal_id;
end; $$;

-- 백업 복원: 현재 데이터를 백업 파일 내용으로 전체 교체
create or replace function public.restore_baby_cube_backup(p_backup jsonb)
returns void language plpgsql security invoker set search_path=public as $$
begin
  if jsonb_typeof(p_backup->'items')<>'array' or jsonb_typeof(p_backup->'history')<>'array'
     or jsonb_typeof(p_backup->'meals')<>'array' or jsonb_typeof(p_backup->'mealItems')<>'array' then
    raise exception 'Invalid backup file structure';
  end if;
  delete from public.meal_entry_items;
  delete from public.meal_entries;
  delete from public.cube_usage;
  delete from public.cubes;

  insert into public.cubes(id,name,category,qty,weight,made,expiry,created_at,updated_at)
  select id,name,coalesce(category,'기타'),qty,coalesce(weight,20),made,expiry,coalesce(created_at,now()),coalesce(updated_at,now())
  from jsonb_to_recordset(p_backup->'items') as x(id uuid,name text,category text,qty numeric,weight numeric,made date,expiry date,created_at timestamptz,updated_at timestamptz);

  insert into public.cube_usage(id,name,cube_id,used_at)
  select id,name,cube_id,used_at from jsonb_to_recordset(p_backup->'history') as x(id uuid,name text,cube_id uuid,used_at timestamptz);

  insert into public.meal_entries(id,meal_date,meal_slot,actual_intake_g,note,created_at,updated_at)
  select id,meal_date,meal_slot,actual_intake_g,note,coalesce(created_at,now()),coalesce(updated_at,now())
  from jsonb_to_recordset(p_backup->'meals') as x(id uuid,meal_date date,meal_slot text,actual_intake_g numeric,note text,created_at timestamptz,updated_at timestamptz);

  insert into public.meal_entry_items(id,meal_id,cube_id,cube_name,used_g,created_at)
  select id,meal_id,cube_id,cube_name,used_g,coalesce(created_at,now())
  from jsonb_to_recordset(p_backup->'mealItems') as x(id uuid,meal_id uuid,cube_id uuid,cube_name text,used_g numeric,created_at timestamptz);
end; $$;

-- RPC 함수 실행 권한: 로그인한 공동 계정만 사용
revoke all on function public.save_baby_meal(date,text,numeric,text,jsonb) from public, anon;
revoke all on function public.delete_baby_meal(uuid) from public, anon;
revoke all on function public.restore_baby_cube_backup(jsonb) from public, anon;
grant execute on function public.save_baby_meal(date,text,numeric,text,jsonb) to authenticated;
grant execute on function public.delete_baby_meal(uuid) to authenticated;
grant execute on function public.restore_baby_cube_backup(jsonb) to authenticated;
