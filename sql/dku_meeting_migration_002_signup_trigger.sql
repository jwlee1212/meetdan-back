-- ============================================================
-- 마이그레이션 002 — 회원가입 트리거 정상화
--
-- 문제
--   auth.users 에 트리거가 하나 걸려 있는데, profiles 를 만들 때
--   id 와 email 만 채우고 login_id / name / gender / campus / dept 를
--   전부 null 로 넣는다. login_id 가 not null 이라 여기서 터지고,
--   트리거 예외는 signUp 트랜잭션 전체를 롤백시킨다.
--
--     HTTP 500 {"code":"23502",
--               "message":"null value in column \"login_id\" of relation
--                          \"profiles\" violates not-null constraint"}
--
--   이 트리거는 dku_meeting_schema*.sql 어디에도 없다. 대시보드에서
--   따로 만들었거나 Supabase 템플릿이 남긴 것으로 보인다.
--
-- 해결
--   트리거를 지우지 않고, 클라이언트가 signUp 시 넘긴 메타데이터
--   (raw_user_meta_data)를 읽어 profiles 를 완전하게 만들도록 고친다.
--
--   클라이언트가 signUp 후 따로 insert 하던 방식보다 나은 이유:
--     · 계정 생성과 프로필 생성이 한 트랜잭션이다. 중간에 실패해서
--       auth.users 에만 행이 남고 그 이메일로 재가입이 막히는 일이 없다.
--     · email_verified_at 을 클라이언트가 직접 쓰지 않는다.
--       (profiles RLS 의 with check 는 id = auth.uid() 뿐이라
--        클라이언트가 쓰게 두면 인증 없이도 채울 수 있었다.)
--
-- 실행: Supabase Dashboard → SQL Editor 에 통째로 붙여넣고 Run
-- ============================================================


-- ------------------------------------------------------------
-- 0. 지금 auth.users 에 뭐가 걸려 있는지 확인 (읽기 전용)
--    아래 1번을 실행하기 전에 먼저 돌려보면 무엇이 지워질지 알 수 있다.
-- ------------------------------------------------------------
-- select t.tgname as 트리거, p.proname as 함수
-- from pg_trigger t
-- join pg_class c      on c.oid  = t.tgrelid
-- join pg_namespace n  on n.oid  = c.relnamespace
-- join pg_proc p       on p.oid  = t.tgfoid
-- where n.nspname = 'auth' and c.relname = 'users' and not t.tgisinternal;


-- ------------------------------------------------------------
-- 1. auth.users 에 걸린 기존 트리거 제거
--    이름을 모르므로 훑어서 지운다. 지운 이름은 NOTICE 로 찍힌다.
--    (tgisinternal = 외래키 등 Postgres 내부 트리거. 건드리지 않는다.)
-- ------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select t.tgname
    from pg_trigger t
    join pg_class c     on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'auth'
      and c.relname = 'users'
      and not t.tgisinternal
  loop
    execute format('drop trigger %I on auth.users', r.tgname);
    raise notice '기존 트리거 제거: %', r.tgname;
  end loop;
end $$;


-- ------------------------------------------------------------
-- 2. 가입 시 profiles 를 완전하게 만드는 함수
--    supabase.auth.signUp({ options: { data: {...} } }) 로 넘어온 값이
--    new.raw_user_meta_data 에 그대로 들어온다.
-- ------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  -- 앱을 거치지 않은 가입(대시보드에서 수동 생성 등)은 메타데이터가 없다.
  -- 그때까지 막아버리면 관리자가 계정을 못 만든다. 조용히 건너뛴다.
  if m ->> 'login_id' is null then
    raise notice 'raw_user_meta_data 에 login_id 가 없어 profiles 생성을 건너뜁니다 (user %)', new.id;
    return new;
  end if;

  insert into public.profiles (
    id, login_id, name, email, gender, campus, dept, email_verified_at
  )
  values (
    new.id,
    m ->> 'login_id',
    m ->> 'name',
    new.email,
    (m ->> 'gender')::gender_t,
    (m ->> 'campus')::campus_t,
    m ->> 'dept',
    -- is_account_active() 가 이 값을 보므로 비어 있으면 팀 생성·채팅이 전부 막힌다.
    --
    -- ⚠ 지금은 "앱이 verify-email 로 확인을 끝낸 뒤에만 가입을 요청한다"는
    --   신뢰에 기대고 있다. 엄밀히 하려면 verify-email 이 인증에 성공한 이메일을
    --   별도 테이블에 남기고, 여기서 그 기록을 조회해 채워야 한다.
    now()
  );

  return new;
end;
$$;


-- ------------------------------------------------------------
-- 3. 트리거 연결
-- ------------------------------------------------------------
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();


-- ------------------------------------------------------------
-- 4. 확인 — 트리거가 하나만 걸려 있어야 한다
-- ------------------------------------------------------------
-- select t.tgname, p.proname
-- from pg_trigger t
-- join pg_class c      on c.oid = t.tgrelid
-- join pg_namespace n  on n.oid = c.relnamespace
-- join pg_proc p       on p.oid = t.tgfoid
-- where n.nspname = 'auth' and c.relname = 'users' and not t.tgisinternal;
