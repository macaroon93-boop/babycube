-- 이유식 큐브 매니저 v3.5 추가 마이그레이션
-- v3.4까지 적용된 프로젝트에서 1회 실행합니다.
-- 기존 식단/가족 한마디/재고 데이터는 삭제하거나 초기화하지 않습니다.

-- 식단에 사용자가 입력한 음식명을 별도 보존합니다.
alter table public.meal_entries
  add column if not exists meal_name varchar(100);

comment on column public.meal_entries.meal_name is
  'User-entered meal/food name; optional for records created before v3.5';

-- 가족 한마디 작성자는 엄마/아빠 외에도 유안이 등 직접 입력한 이름을 허용합니다.
alter table public.family_messages
  drop constraint if exists family_messages_author_check;

alter table public.family_messages
  add constraint family_messages_author_check
  check (char_length(trim(author)) between 1 and 20);
