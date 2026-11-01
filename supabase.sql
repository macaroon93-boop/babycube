-- 이유식 큐브 공동관리 앱: Supabase SQL Editor에서 전체 실행
create extension if not exists pgcrypto;

create table if not exists public.cubes (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text not null default '기타',
  qty integer not null default 0 check (qty >= 0),
  weight numeric not null default 20 check (weight > 0),
  made date,
  expiry date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.cube_usage (
  id uuid primary key default gen_random_uuid(),
  cube_id uuid,
  name text not null,
  used_at timestamptz not null default now()
);

alter table public.cubes enable row level security;
alter table public.cube_usage enable row level security;

-- 로그인한 사용자만 읽기/쓰기 가능.
-- 부부가 동일한 공동 계정으로 로그인하므로 두 기기에서 동일한 데이터에 접근.
drop policy if exists "authenticated users manage cubes" on public.cubes;
create policy "authenticated users manage cubes"
on public.cubes for all to authenticated
using (true) with check (true);

drop policy if exists "authenticated users manage usage" on public.cube_usage;
create policy "authenticated users manage usage"
on public.cube_usage for all to authenticated
using (true) with check (true);

-- Supabase Realtime publication에 두 테이블 추가 (이미 포함된 경우 건너뜀)
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'cubes'
  ) then
    alter publication supabase_realtime add table public.cubes;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'cube_usage'
  ) then
    alter publication supabase_realtime add table public.cube_usage;
  end if;
end $$;
