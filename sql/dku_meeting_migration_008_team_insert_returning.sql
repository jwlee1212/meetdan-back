-- ============================================================
-- 마이그레이션 008 — 팀을 만든 사람이 방금 만든 팀을 볼 수 있게 한다
--
-- 증상. 팀 만들기 → "[오류] 권한이 없어요. 다시 로그인해주세요."
--   이 문구는 api/client.ts 의 describeDbError 가 SQLSTATE 42501(RLS 위반)에
--   붙여둔 안내다. 즉 세션이 끊긴 게 아니라 정책에 막힌 것이다.
--
-- 원인. INSERT ... RETURNING 은 SELECT 정책까지 통과해야 한다
--   createTeam 은 이렇게 부른다.
--       supabase.from("teams").insert({...}).select("id").single()
--   .select() 가 붙으면 PostgREST 는 INSERT ... RETURNING 으로 보내고,
--   PostgreSQL 은 이때 "돌려줄 행이 SELECT 정책을 통과하는가"를 함께 본다.
--   (문서 'Policies Applied by Command Type': INSERT ... RETURNING → SELECT USING)
--
--   그 시점의 teams_select 조건을 새 팀에 대입해 보면 전부 거짓이다.
--       is_admin()                     → 아님
--       is_team_member(id)             → ❌ team_members 에 아직 내 행이 없다
--       is_matched_with_team(id)       → 아님
--       status = 'ACTIVE'              → 새 팀은 'RECRUITING'
--
--   팀장을 team_members 에 넣는 teams_add_owner 는 after insert 트리거라,
--   RETURNING 검사가 끝난 뒤에야 돈다. 즉 '팀장이 등록되기 전 한순간'에
--   자기가 만든 팀이 자기 눈에 안 보이고, 그 한순간을 RETURNING 이 정확히 밟는다.
--   특정 계정 문제가 아니라 누가 언제 눌러도 똑같이 실패한다.
--
-- 해결. 소유자는 언제나 자기 팀을 본다
--   owner_id = auth.uid() 를 teams_select 에 더한다. 팀장은 어차피
--   team_members 에도 들어가므로 실제로 보이는 범위는 넓어지지 않는다.
--   트리거가 돌기 전 그 한순간의 구멍만 메운다.
--
-- 실행: Supabase Dashboard → SQL Editor 에 통째로 붙여넣고 Run
-- ============================================================


-- ------------------------------------------------------------
-- 0. 먼저 확인 — 42501 의 원인이 정말 이것인지 가른다
--
--    42501 이 나는 길은 두 갈래고 에러 문구가 똑같아서 구분이 안 된다.
--      (a) 위에 적은 RETURNING 문제        → 아래 2번이 고친다
--      (b) is_account_active() 가 false    → 3번을 봐야 한다
--          teams_insert 정책이 이 함수를 보는데, 이 함수는
--          status in ('active','warned') / deleted_at is null /
--          email_verified_at is not null 을 모두 요구한다.
--
--    '내아이디' 를 팀 생성에 실패한 계정의 login_id 로 바꿔서 실행할 것.
--    (SQL Editor 에서는 auth.uid() 가 null 이라 login_id 로 찾아야 한다.)
-- ------------------------------------------------------------
-- select
--   p.login_id,
--   p.status,
--   p.deleted_at,
--   p.email_verified_at,
--   (p.status in ('active', 'warned')
--     and p.deleted_at is null
--     and p.email_verified_at is not null) as 팀생성가능
-- from profiles p
-- where p.login_id = '내아이디';
--
--   팀생성가능 = true  → (a) 다. 아래 2번만 실행하면 된다.
--   팀생성가능 = false → (b) 도 겹쳐 있다. 2번을 실행한 뒤 3번을 읽을 것.


-- ------------------------------------------------------------
-- 1. 정책 교체
--    v2 스키마의 teams_select 에 owner_id 한 줄만 더한 것이다.
-- ------------------------------------------------------------
drop policy if exists teams_select on teams;

create policy teams_select on teams for select to authenticated
using (
  is_admin()
  -- ⭐ 008 신규. 트리거가 team_members 를 채우기 전에도 내 팀은 내가 본다.
  or owner_id = auth.uid()
  or is_team_member(id)
  or is_matched_with_team(id)
  or (status = 'ACTIVE' and not is_blocked_with_team(id))
);


-- ------------------------------------------------------------
-- 2. 확인 — 팀장이 방금 만든 팀이 보이는가
--    앱에서 팀 만들기를 다시 눌러보는 게 가장 확실하다.
-- ------------------------------------------------------------
-- select id, title, status, filled_count, invite_code
-- from teams
-- where owner_id = (select id from profiles where login_id = '내아이디')
-- order by created_at desc
-- limit 3;


-- ------------------------------------------------------------
-- 3. (b) 였을 때만 — email_verified_at 백필
--
--    마이그레이션 002 의 handle_new_user 트리거가 붙기 전에 만든 계정은
--    이 값이 비어 있다. 그런 계정은 팀 생성·팀 참여·채팅 전송이 전부 막힌다.
--
--    ⚠️ 아래는 "이메일 인증을 안 한 계정을 인증한 것으로 친다"는 뜻이다.
--       개발 중에 만든 테스트 계정에만 쓸 것. 운영 데이터에는 쓰지 말 것.
--       (제대로 된 길은 verify-email Edge Function 이 이 값을 쓰게 하는 것이다.)
-- ------------------------------------------------------------
-- update profiles
-- set email_verified_at = now()
-- where login_id = '내아이디'
--   and email_verified_at is null;
