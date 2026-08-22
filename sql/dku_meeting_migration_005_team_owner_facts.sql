-- ============================================================
-- 마이그레이션 005 — 팀의 '생성자에게서 오는 값'을 서버가 채운다
--
-- 문제 1. dept / gender 를 클라이언트가 정한다
--   스키마 주석은 teams.dept 를 "팀 대표 학과 (생성자 학과에서 가져옴)",
--   gender 를 "과팅이므로 팀은 동성으로 구성"이라고 못 박아 두었지만,
--   teams_insert 정책은 owner_id = auth.uid() 만 본다. 즉 값 자체는
--   클라이언트가 보내는 대로 들어간다. 마음만 먹으면 소프트웨어학과
--   학생이 '의예과 여성 팀'을 만들 수 있고, 게시판 필터가 통째로 무의미해진다.
--   (마이그레이션 003 에서 profiles 고정 컬럼을 막은 것과 같은 종류의 구멍이다.)
--
--   campus 는 제외했다. write.tsx 가 죽전/천안을 직접 고르게 하고 있고,
--   실제로 다른 캠퍼스에서 만나는 팀이 있을 수 있어 본인 선택이 맞다.
--
-- 문제 2. '인원이 다 모여야 공개' 규칙이 화면에만 있다
--   my_team.tsx 는 정원이 차지 않으면 공개 버튼 대신 자물쇠를 보여주지만,
--   서버는 status = 'ACTIVE' 로 바꾸는 요청을 그대로 받는다.
--   정원 미달 팀이 게시판(teams_select 의 status='ACTIVE')에 올라갈 수 있다.
--
-- 실행: Supabase Dashboard → SQL Editor 에 통째로 붙여넣고 Run
-- ============================================================


-- ------------------------------------------------------------
-- 1. 팀 생성 시 dept / gender 를 생성자 프로필에서 복사
--    BEFORE INSERT 라 not null 검사보다 먼저 돈다. 클라이언트는
--    두 컬럼을 아예 보내지 않아도 되고, 보내더라도 여기서 덮인다.
-- ------------------------------------------------------------
create or replace function set_team_owner_facts()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_dept   text;
  v_gender gender_t;
begin
  select dept, gender into v_dept, v_gender
  from profiles where id = new.owner_id;

  if not found then
    raise exception '프로필이 없어 팀을 만들 수 없습니다';
  end if;

  new.dept   := v_dept;
  new.gender := v_gender;
  return new;
end; $$;

drop trigger if exists teams_set_owner_facts on teams;
create trigger teams_set_owner_facts
before insert on teams
for each row execute function set_team_owner_facts();


-- ------------------------------------------------------------
-- 2. 정원이 찬 팀만 게시판에 공개
--
--    'ACTIVE 로 바뀌는 순간'만 본다. 이미 공개된 팀에서 팀원이 나가
--    sync_team_fill() 이 filled_count 를 낮추는 경우까지 막으면
--    (그때도 status 는 ACTIVE 그대로다) 팀 나가기가 통째로 실패한다.
-- ------------------------------------------------------------
create or replace function assert_team_full_before_publish()
returns trigger language plpgsql as $$
begin
  if new.status = 'ACTIVE'
     and old.status is distinct from 'ACTIVE'
     and new.filled_count < new.capacity then
    raise exception '팀원이 다 모여야 게시판에 공개할 수 있습니다'
      using errcode = 'check_violation';
  end if;
  return new;
end; $$;

drop trigger if exists teams_guard_publish on teams;
create trigger teams_guard_publish
before update on teams
for each row execute function assert_team_full_before_publish();
