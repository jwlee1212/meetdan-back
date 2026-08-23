-- ============================================================
-- 백필 — auth.users 는 남았는데 profiles 가 비어 있을 때
--
-- ⚠️ 이 파일은 마이그레이션이 아니다. 구조를 바꾸지 않고, 사고가 났을 때
--    한 번 돌리는 데이터 복구 스크립트다. 001~011 처럼 순서대로 쌓이는
--    파일이 아니므로 평소에는 실행할 일이 없다.
--
-- 언제 쓰나
--   가입은 분명히 했는데 로그인이 "아이디 또는 비밀번호가 올바르지 않습니다"
--   로 막히고, 아래가 참일 때.
--
--     select count(*) from profiles;                    -- 0 또는 예상보다 적다
--     select count(*) from auth.users;                  -- 계정은 그대로 있다
--
--   가장 흔한 원인은 dku_meeting_schema_v2.sql 을 다시 실행한 것이다.
--   그 파일 앞머리에 `drop table if exists profiles cascade;` 가 있어서
--   돌릴 때마다 프로필이 통째로 사라진다. auth.users 는 auth 스키마라
--   그대로 남는다 — 그래서 '계정은 있는데 프로필만 없는' 상태가 된다.
--
-- 왜 손으로 채워야 하나
--   handle_new_user 트리거는 auth.users 에 새 행이 들어올 때만 돈다.
--   이미 가입해 있는 계정은 아무리 기다려도 프로필이 생기지 않는다.
--   다행히 가입 때 보낸 값이 auth.users.raw_user_meta_data 에 그대로
--   남아 있어서, 트리거가 그 순간에 했어야 할 일을 여기서 대신 한다.
--
--   아래 insert 의 컬럼과 값은 마이그레이션 006 의 handle_new_user 와
--   한 줄씩 그대로 대응한다. 일부러 똑같이 맞춰 두었다 — 다르게 채우면
--   자동으로 만들어진 계정과 손으로 채운 계정이 미묘하게 어긋난다.
--
-- 전제
--   마이그레이션 002~006 이 (다시) 적용되어 있어야 한다.
--   특히 006 이 profiles.birth_year 를 만든다. 그 전에 돌리면
--   "column birth_year does not exist" 로 터진다.
--
-- 여러 번 돌려도 안전하다
--   이미 프로필이 있는 계정은 마지막 not exists 가 걸러낸다.
--
-- 비밀번호는 건드리지 않는다
--   비밀번호는 auth.users 에 그대로 있다. 프로필만 채우면 예전 아이디와
--   비밀번호로 다시 로그인된다.
--
-- 실행: Supabase Dashboard → SQL Editor 에 통째로 붙여넣고 Run
-- ============================================================


-- ------------------------------------------------------------
-- 1. 미리 보기 — 무엇이 채워지고 무엇이 안 되는지 먼저 본다
--
--    SQL Editor 는 마지막 문장의 결과만 보여준다. 그래서 여기 두면 아래
--    insert 에 가려진다. 먼저 확인하고 싶으면 이 블록만 복사해서 따로 돌릴 것.
--    (아래 3번이 같은 내용을 실행 후에 보여준다)
-- ------------------------------------------------------------
-- select u.email,
--        u.raw_user_meta_data ->> 'login_id' as 아이디,
--        u.raw_user_meta_data ->> 'name'     as 이름,
--        p.id is not null                    as 프로필_있음
-- from auth.users u
-- left join profiles p on p.id = u.id
-- order by u.created_at desc;


-- ------------------------------------------------------------
-- 2. 백필
--
--    where 절이 긴 이유: profiles 의 login_id / name / gender / campus /
--    dept 는 전부 not null 이다. 메타데이터에 하나라도 빠진 계정이 섞이면
--    insert 전체가 터져서 멀쩡한 계정까지 하나도 안 들어간다.
--    그래서 채울 수 있는 것만 넣고, 못 채우는 계정은 3번이 이유와 함께
--    보여준다.
-- ------------------------------------------------------------
insert into profiles (
  id, login_id, name, email, gender, campus, dept, birth_year, email_verified_at
)
select
  u.id,
  u.raw_user_meta_data ->> 'login_id',
  u.raw_user_meta_data ->> 'name',
  u.email,
  (u.raw_user_meta_data ->> 'gender')::gender_t,
  (u.raw_user_meta_data ->> 'campus')::campus_t,
  u.raw_user_meta_data ->> 'dept',
  nullif(u.raw_user_meta_data ->> 'birth_year', '')::int,
  -- 트리거와 같다. 앱이 verify-email 을 끝낸 뒤에만 가입을 요청한다는
  -- 신뢰에 기대고 있다(마이그레이션 002 주석 참고). 비어 있으면
  -- is_account_active() 가 false 라 팀 생성·채팅이 전부 막힌다.
  now()
from auth.users u
where u.raw_user_meta_data ->> 'login_id' is not null
  and u.raw_user_meta_data ->> 'name'     is not null
  and u.raw_user_meta_data ->> 'gender'   is not null
  and u.raw_user_meta_data ->> 'campus'   is not null
  and u.raw_user_meta_data ->> 'dept'     is not null
  -- profiles.email 의 check 제약과 같은 조건. 다른 도메인 계정이 섞여
  -- 있으면 여기서 걸러야 insert 가 통째로 실패하지 않는다.
  and u.email ~* '^[a-zA-Z0-9._%+-]+@dankook\.ac\.kr$'
  and not exists (select 1 from profiles p where p.id = u.id);


-- ------------------------------------------------------------
-- 3. 결과
--
--    '복구 불가' 로 남은 계정은 채울 재료 자체가 없다. 지우고 앱에서
--    다시 가입하는 수밖에 없다.
--
--      delete from auth.users u
--      where not exists (select 1 from profiles p where p.id = u.id);
--
--    ⚠️ 위 delete 는 되돌릴 수 없다. 반드시 아래 결과를 먼저 확인하고,
--       지워도 되는 계정만 남아 있는지 눈으로 본 뒤에 실행할 것.
-- ------------------------------------------------------------
select
  u.email,
  u.raw_user_meta_data ->> 'login_id' as 아이디,
  case
    when p.id is not null then
      '✅ 정상 — 로그인 가능'
    when u.raw_user_meta_data ->> 'login_id' is null then
      '⛔ 복구 불가 — 메타데이터에 login_id 가 없다 (앱을 거치지 않은 가입)'
    when u.raw_user_meta_data ->> 'name'   is null
      or u.raw_user_meta_data ->> 'gender' is null
      or u.raw_user_meta_data ->> 'campus' is null
      or u.raw_user_meta_data ->> 'dept'   is null then
      '⛔ 복구 불가 — 가입 정보가 일부만 남아 있다'
    when u.email !~* '^[a-zA-Z0-9._%+-]+@dankook\.ac\.kr$' then
      '⛔ 복구 불가 — 단국대 메일이 아니다'
    else
      '⚠️ 확인 필요 — 위 조건에 걸리지 않았는데 프로필이 없다'
  end as 상태,
  u.created_at
from auth.users u
left join profiles p on p.id = u.id
order by u.created_at desc;
