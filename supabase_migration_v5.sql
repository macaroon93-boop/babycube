-- 이유식 큐브 매니저 v3.3 추가 마이그레이션
-- v4 마이그레이션을 이미 적용한 프로젝트에서 1회 실행합니다.
-- 기존 데이터/테이블을 삭제하거나 초기화하지 않습니다.

-- meal_slot의 기존 3종 제한을 아침/점심/저녁/간식 4종으로 확장합니다.
do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
    where conrelid='public.meal_entries'::regclass and contype='c'
      and pg_get_constraintdef(oid) ilike '%meal_slot%'
  loop
    execute format('alter table public.meal_entries drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.meal_entries
  add constraint meal_entries_meal_slot_check
  check (meal_slot in ('아침','점심','저녁','간식'));

-- 식단 사진과 재료 분류를 식단 항목에 보존합니다.
alter table public.meal_entries
  add column if not exists photo_data text;
alter table public.meal_entry_items
  add column if not exists cube_category text;

comment on column public.meal_entries.photo_data is
  'Compressed meal photo as data:image/jpeg;base64 URL; optional';

-- 간식 슬롯과 재료 분류 저장을 지원합니다. 기존 재고 차감/복구 로직은 유지합니다.
create or replace function public.save_baby_meal_v4(
  p_date date, p_slot text, p_actual_intake_g numeric, p_note text, p_items jsonb
) returns void language plpgsql security invoker set search_path=public as $$
declare
  v_meal_id uuid; v_item record; v_cube public.cubes%rowtype; v_old record;
  v_meal_item_id uuid; v_used_g numeric; v_thawed_used numeric; v_frozen_used numeric;
begin
  if p_slot not in ('아침','점심','저녁','간식') then raise exception 'Invalid meal slot'; end if;
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
    insert into public.meal_entry_items(meal_id,cube_id,cube_name,cube_category,used_g,used_qty,reaction,used_thawed_qty)
    values(v_meal_id,v_cube.id,v_cube.name,v_cube.category,v_used_g,v_item.used_qty,coalesce(nullif(v_item.reaction,''),'미기록'),v_thawed_used)
    returning id into v_meal_item_id;
    insert into public.cube_usage(name,cube_id,used_at,usage_type,used_qty,used_thawed_qty,meal_item_id)
    values(v_cube.name,v_cube.id,now(),'meal',v_item.used_qty,v_thawed_used,v_meal_item_id);
  end loop;
end; $$;
