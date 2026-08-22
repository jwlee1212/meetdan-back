-- ============================================================
-- 마이그레이션 010 — 팀은 동성으로만 채워진다
--
-- 문제
--   teams.gender 는 팀장 프로필에서 복사된다(마이그레이션 005·006의
--   set_team_owner_facts). 그런데 팀에 들어오는 '팀원'의 성별은 아무도
--   보지 않는다. 초대 코드만 알면 이성도 그대로 합류한다.
--
--   그러면 마이그레이션 009 가 세운 '이성 팀에만 신청할 수 있다' 규칙이
--   무의미해진다. 남성 팀장 + 여성 팀원으로 채운 팀이 남성 팀으로 표시된
--   채 여성 팀에 신청할 수 있기 때문이다. 게시판의 성별 표시와 상세
--   화면의 팀원 목록도 서로 어긋난다.
--
--   지금까지 이게 안 드러난 이유는 하나다 — 팀에 들어오는 길이 초대 코드
--   하나뿐이고, 그 코드를 아는 사람은 대개 같은 과 친구들이라서.
--   규칙이 사람의 습관에만 기대고 있었다.
--
-- 해결
--   team_members 에 BEFORE INSERT 가드를 하나 더 세운다.
--   팀에 들어오는 길이 여럿(join_team_by_code RPC, 팀 생성 시 teams_add_owner,
--   나중에 생길 수도 있는 초대 링크)이라 RPC 가 아니라 테이블에 건다.
--   어느 길로 들어오든 이 트리거를 지나야 한다.
--
--   팀장 본인은 자동으로 통과한다. teams.gender 가 팀장 프로필에서
--   복사된 값이라 항상 같기 때문이다.
--
-- 트리거 순서
--   team_members 의 BEFORE INSERT 는 이름 알파벳 순으로 돈다.
--     team_members_capacity_guard  (MATCHED → 정원)
--     team_members_gender_guard    (성별)            ← 이번에 추가
--   즉 정원이 찬 팀에 이성이 들어오려 하면 '정원이 가득 찼습니다'가 먼저
--   뜬다. 둘 다 거절이므로 결과는 같다.
--
-- 실행: Supabase Dashboard → SQL Editor 에 통째로 붙여넣고 Run
--       (전제: dku_meeting_schema_v2.sql + 마이그레이션 002~009)
--       검증: dku_meeting_verify_match_flow.sql 의 4-5 / 4-6
-- ============================================================


-- ------------------------------------------------------------
-- 1. 가드
--
--    security definer 인 이유: 들어오려는 사람은 팀 행을 못 볼 수도 있고
--    (비공개 팀), 상대 프로필이 차단으로 가려져 있을 수도 있다. 정책에
--    걸려 값을 못 읽으면 '성별을 알 수 없어서 통과'가 되어 버린다.
--
--    값이 없으면 통과시키지 않고 막는다. 팀이나 프로필이 사라진 상태로
--    팀원을 넣는 건 어차피 정상적인 길이 아니다.
-- ------------------------------------------------------------
create or replace function assert_member_gender_matches()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_team_gender   gender_t;
  v_member_gender gender_t;
begin
  select gender into v_team_gender from teams   where id = new.team_id;
  if not found then
    raise exception '팀을 찾을 수 없습니다' using errcode = 'check_violation';
  end if;

  select gender into v_member_gender from profiles where id = new.user_id;
  if not found then
    raise exception '프로필이 없어 팀에 참여할 수 없습니다' using errcode = 'check_violation';
  end if;

  if v_member_gender <> v_team_gender then
    raise exception '같은 성별끼리만 팀을 이룰 수 있습니다'
      using errcode = 'check_violation';
  end if;

  return new;
end; $$;

drop trigger if exists team_members_gender_guard on team_members;
create trigger team_members_gender_guard
before insert on team_members
for each row execute function assert_member_gender_matches();


-- ------------------------------------------------------------
-- 2. 이미 섞여 있는 팀 찾기
--
--    트리거는 앞으로 들어올 사람만 막는다. 이미 들어와 있는 팀원은
--    그대로 남으므로, 아래로 한 번 확인하고 손으로 정리할 것.
--    (지우는 쪽이 아니라 사람에게 알리는 쪽이 맞다고 보고 자동 정리는
--     넣지 않았다. 팀원을 지우면 sync_team_fill 이 팀을 게시판에서
--     내리고, 당사자는 이유도 모른 채 팀에서 사라진다.)
-- ------------------------------------------------------------
-- select t.id, t.title, t.gender as 팀성별,
--        p.name, p.gender as 팀원성별
-- from team_members m
-- join teams t    on t.id = m.team_id
-- join profiles p on p.id = m.user_id
-- where p.gender <> t.gender
-- order by t.created_at desc;
