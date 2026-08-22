-- ============================================================
-- 마이그레이션 007 — 게시판에 공개된 팀의 팀원을 볼 수 있게 한다
--
-- 문제. 홈 피드에서 팀을 눌러 들어가면 "팀원 0/4" 가 뜬다
--   teams_select 는 status='ACTIVE' 인 남의 팀을 통과시킨다. 그래서 게시판
--   목록(제목·학과·인원·평균 나이)까지는 잘 보인다. 그런데
--     team_members_select = is_team_member or is_matched_with_team or is_admin
--   이라, 아직 매칭되지 않은 남의 팀은 '누가 그 팀에 있는가' 한 줄이 통째로
--   가려진다. api/client.ts 의 TEAM_SELECT 는 팀원 카드를 team_members →
--   profiles 조인으로 가져오므로, 상세 화면(post/[id].tsx)의 팀원 목록이 빈다.
--
--   신청할지 말지는 어떤 사람들이 있는지를 보고 정하는 것이라, 팀원이 안 보이면
--   게시판이 사실상 제목만 남는다.
--
-- 결론. teams_select 와 같은 조건으로 맞춘다
--   팀을 게시판에 올린다는 건 "우리 팀을 보여주고 신청을 받겠다"는 뜻이다.
--   프로필 자체는 이미 profiles_select 로 열려 있고(탈퇴·정지·차단 제외),
--   가려져 있던 건 소속 관계 한 줄뿐이다. 새로 여는 범위는
--     · 공개된 팀(status='ACTIVE')의 팀원 행
--     · 차단 관계인 팀은 그대로 제외
--   비공개(RECRUITING/READY) 팀과 매칭이 끝난(MATCHED) 팀은 지금처럼 가려진다.
--
-- 실행: Supabase Dashboard → SQL Editor 에 통째로 붙여넣고 Run
-- ============================================================


-- ------------------------------------------------------------
-- 1. '게시판에 올라와 있는 팀인가' 판정
--
--    security definer 인 이유는 두 가지다.
--      · 정책 안에서 teams 를 직접 읽으면 teams_select 가 다시 걸린다.
--        (teams_select → is_team_member 는 definer 라 되돌아오지 않지만,
--         정책끼리 얽히는 구조는 나중에 한 줄만 고쳐도 재귀가 된다)
--      · 기존 헬퍼(is_team_member, is_blocked_with_team …)와 형태를 맞춘다.
-- ------------------------------------------------------------
create or replace function is_listed_team(p_team_id uuid)
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (
    select 1 from teams t
    where t.id = p_team_id and t.status = 'ACTIVE'
  )
  and not is_blocked_with_team(p_team_id);
$$;

revoke all on function is_listed_team(uuid) from public;
grant execute on function is_listed_team(uuid) to authenticated;


-- ------------------------------------------------------------
-- 2. team_members 조회 정책에 한 줄 추가
--    (insert / delete 정책은 건드리지 않는다. 남의 팀에 사람을 넣거나
--     빼는 건 여전히 본인·팀장·관리자만 할 수 있다.)
-- ------------------------------------------------------------
drop policy if exists team_members_select on team_members;

create policy team_members_select on team_members for select to authenticated
using (
  is_team_member(team_id)
  or is_matched_with_team(team_id)
  or is_listed_team(team_id)
  or is_admin()
);


-- ------------------------------------------------------------
-- 3. 확인
--
--    다른 계정으로 로그인해 공개 팀 하나를 골라 실행해 보면
--    팀원 수만큼 행이 나와야 한다.
-- ------------------------------------------------------------
-- select t.title, p.name, m.is_owner
-- from teams t
-- join team_members m on m.team_id = t.id
-- join profiles p on p.id = m.user_id
-- where t.status = 'ACTIVE';
