-- ============================================================
-- 마이그레이션 001 — 프론트엔드(meetdan-front) 정렬
--
-- 기준 스키마: dku_meeting_schema.sql
-- 기준 프론트: store/useStore.ts, utils/auth.ts, app/**
--
-- 원칙: 기존 테이블·RLS·트리거를 갈아엎지 않고 컬럼 추가 위주로 조정한다.
--       이미 검증된 profiles / blocks / reports 정책은 건드리지 않는다.
--       (단 하나, matches_update 만 예외 — 아래 [RLS-3] 참고)
--
-- 실행 순서 주의:
--   STEP 0 (enum 값 추가)은 반드시 따로 실행하고 커밋한 뒤 STEP 1~ 을 실행한다.
--   Postgres는 같은 트랜잭션 안에서 새로 추가한 enum 값을 사용할 수 없다.
-- ============================================================


-- ============================================================
-- STEP 0. 타입 — 여기까지 실행 후 커밋(또는 SQL Editor에서 따로 실행)
-- ============================================================

-- 캠퍼스: 프론트 constants/departments.ts 의 Campus 타입과 값까지 동일하게 맞춘다
do $$ begin
  create type campus_t as enum ('죽전', '천안');
exception when duplicate_object then null; end $$;

-- 메시지 종류: 프론트 chat/[id].tsx 는 일반/시스템/종료제안 세 가지를 그린다
do $$ begin
  create type message_kind as enum ('user', 'system', 'proposal');
exception when duplicate_object then null; end $$;

-- 채팅방 신고: 프론트는 '사용자 신고'와 '채팅방 신고' 두 가지만 쓴다
alter type report_target add value if not exists 'room';

-- ------------------------------------------------------------
-- ⬆⬆ 여기까지 실행하고 커밋한 뒤 아래를 실행할 것 ⬆⬆
-- ------------------------------------------------------------


-- ============================================================
-- STEP 1. profiles
--   프론트 CurrentUser(store) + UserProfile/Account(utils/auth.ts) 대응
-- ============================================================

-- 홈 탭 기본 필터, 팀 생성 기본값이 내 캠퍼스라 반드시 필요하다
alter table profiles add column if not exists campus campus_t;

-- 마이 탭 편집 항목. bio 는 이미 있고 mbti / 아바타 인덱스만 없다
alter table profiles add column if not exists mbti text
  check (mbti is null or mbti ~ '^[EI][SN][TF][JP]$');

-- 프론트는 이미지 URL이 아니라 번들 에셋 인덱스(0~11)를 저장한다.
-- avatar_url 은 나중에 실제 사진을 올릴 때를 위해 그대로 둔다.
alter table profiles add column if not exists avatar_idx int not null default 0
  check (avatar_idx between 0 and 11);

-- 프로필 화면이 가입 이메일을 그대로 보여준다(app/(tabs)/profile.tsx: info.email).
-- auth.users.email 은 클라이언트에서 조인 조회가 안 되므로 인증 시점에 복사해 둔다.
-- verify-email Edge Function 에서 email 과 email_verified_at 을 함께 기록하면 된다.
alter table profiles add column if not exists email text;

-- 프론트 회원가입/로그인은 이메일이 아니라 '아이디(userId)'를 받는다.
-- Supabase Auth 는 이메일 기반이므로 아래 컬럼은 표시/중복확인 용도로만 쓰고,
-- 실제 인증은 이메일+비밀번호로 가는 것을 권장한다. (README 아래 [지적 5] 참고)
alter table profiles add column if not exists login_id text unique
  check (login_id is null or char_length(login_id) between 4 and 20);


-- ============================================================
-- STEP 2. teams
--   프론트 Team 은 스키마의 teams + posts 를 하나로 합친 모양이다.
--   팀은 게시글 없이도(비공개, RECRUITING/READY) 정원·태그·초대코드를 갖는다.
--   → 이 값들은 posts 가 아니라 teams 에 있어야 한다.
-- ============================================================

alter table teams add column if not exists campus campus_t;
alter table teams add column if not exists dept text;              -- Team.dept
alter table teams add column if not exists avg_age int             -- Team.age (팀 평균 나이)
  check (avg_age is null or avg_age between 18 and 40);
alter table teams add column if not exists tags text[] not null default '{}';  -- Team.tags

-- Team.count (정원). 게시글이 없어도 필요하므로 teams 에 둔다.
alter table teams add column if not exists capacity int not null default 3
  check (capacity between 2 and 6);

-- Team.currentCount. team_members count 로 매번 세면 목록 화면이 N+1 이 된다.
-- 아래 트리거로 자동 유지한다.
alter table teams add column if not exists filled_count int not null default 0
  check (filled_count >= 0);

-- Team.inviteCode. my_team.tsx 의 '코드로 참여' 가 이 값 없이는 동작하지 않는다.
alter table teams add column if not exists invite_code text unique
  check (invite_code is null or invite_code ~ '^[A-Z0-9]{6}$');

-- 기존 행 백필 (개발 데이터가 있다면)
update teams t
set filled_count = (select count(*) from team_members m where m.team_id = t.id)
where filled_count = 0;


-- filled_count 자동 유지
create or replace function sync_team_filled_count()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  update teams t
  set filled_count = (select count(*) from team_members m where m.team_id = t.id)
  where t.id = coalesce(new.team_id, old.team_id);
  return coalesce(new, old);
end; $$;

drop trigger if exists team_members_sync_count on team_members;
create trigger team_members_sync_count
after insert or delete on team_members
for each row execute function sync_team_filled_count();


-- 정원 초과 방지 (프론트 joinTeamByCode 가 검사하지만 서버에서도 막는다)
create or replace function assert_team_not_full()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_capacity int;
  v_filled   int;
begin
  select capacity, filled_count into v_capacity, v_filled
  from teams where id = new.team_id for update;

  if v_filled >= v_capacity then
    raise exception '팀 정원이 가득 찼습니다' using errcode = 'check_violation';
  end if;
  return new;
end; $$;

drop trigger if exists team_members_capacity_guard on team_members;
create trigger team_members_capacity_guard
before insert on team_members
for each row execute function assert_team_not_full();


-- ============================================================
-- STEP 3. posts
--   프론트는 팀 1개당 게시글 1개(공개/비공개 토글)만 다룬다.
--   toggleTeamStatus() 가 여러 번 눌려도 게시글이 쌓이지 않게 막는다.
-- ============================================================

create unique index if not exists posts_one_active_per_team
  on posts(team_id) where is_active;

-- posts.member_count 는 teams.capacity 와 중복이다. 새로 만드는 게시글은
-- teams.capacity 를 그대로 복사해 넣는 것으로 통일한다. (아래 [지적 3] 참고)


-- ============================================================
-- STEP 4. matches — 확정 약속 (store: Match.confirmedPlan)
--   별도 테이블 대신 컬럼 3개. 매칭 1건당 약속 1건이라 1:1 이다.
-- ============================================================

alter table matches add column if not exists plan_date  date;
alter table matches add column if not exists plan_time  time;   -- "HH:mm"
alter table matches add column if not exists plan_place text
  check (plan_place is null or char_length(plan_place) <= 100);

-- 날짜/시간/장소는 항상 함께 채워지거나 함께 비어야 한다 (프론트 PlanSheet 동작과 동일)
alter table matches drop constraint if exists matches_plan_all_or_none;
alter table matches add constraint matches_plan_all_or_none check (
  (plan_date is null and plan_time is null and plan_place is null)
  or (plan_date is not null and plan_time is not null)
);

-- history.tsx 가 '다음 약속'을 위로 올린다
create index if not exists idx_matches_plan_date on matches(plan_date)
  where status = 'accepted' and plan_date is not null;


-- ============================================================
-- STEP 5. messages — 시스템 메시지 / 종료 제안 카드
-- ============================================================

alter table messages add column if not exists kind message_kind not null default 'user';

-- 시스템 메시지·종료 제안 카드는 보낸 사람이 없다
alter table messages alter column sender_id drop not null;

-- 종료 제안 카드의 결정 상태 (프론트 ProposalCard: 동의 / 더 대화할래요)
alter table messages add column if not exists proposal_result text
  check (proposal_result is null or proposal_result in ('accepted', 'rejected'));

alter table messages drop constraint if exists messages_sender_required;
alter table messages add constraint messages_sender_required check (
  (kind = 'user' and sender_id is not null)
  or (kind <> 'user')
);


-- ============================================================
-- STEP 6. blocks — 차단 목록 화면에 필요한 것
-- ============================================================

-- 어느 방에서 차단했는지 (store: BlockedUser.roomId)
alter table blocks add column if not exists room_id uuid references chat_rooms(id) on delete set null;

-- ⚠ 핵심: profiles_select 정책이 `not is_blocked_with(id)` 이라
--    내가 차단한 사람의 profiles 행은 나에게 조회되지 않는다.
--    그런데 app/settings/blocked.tsx 는 차단한 사람의 이름·학과를 보여준다.
--    profiles 정책을 고치는 대신(이미 검증됨) 차단 시점 값을 스냅샷으로 남긴다.
alter table blocks add column if not exists blocked_nickname text;
alter table blocks add column if not exists blocked_department text;

create or replace function snapshot_blocked_profile()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  select nickname, department
  into new.blocked_nickname, new.blocked_department
  from profiles where id = new.blocked_id;
  return new;
end; $$;

drop trigger if exists blocks_snapshot_profile on blocks;
create trigger blocks_snapshot_profile
before insert on blocks
for each row execute function snapshot_blocked_profile();


-- ============================================================
-- STEP 7. reports
-- ============================================================

-- 어느 채팅방에서 신고했는지 (store: Report.roomId) — 운영자가 대화를 열어보는 용도
alter table reports add column if not exists room_id uuid references chat_rooms(id) on delete set null;

-- reason 은 자유 텍스트였다. 프론트 REPORT_REASONS 6종으로 고정한다.
-- 기존 데이터가 있으면 not valid 로 붙이고 정리 후 validate 할 것.
alter table reports drop constraint if exists reports_reason_allowed;
alter table reports add constraint reports_reason_allowed check (
  reason in ('ABUSE', 'SEXUAL', 'SPAM', 'FRAUD', 'NO_SHOW', 'ETC')
);

-- 프론트 submitReport() 는 같은 방·같은 대상 중복 신고를 거부한다. 서버에서도 막는다.
create unique index if not exists reports_no_duplicate
  on reports(reporter_id, target_type, target_id, coalesce(room_id, '00000000-0000-0000-0000-000000000000'::uuid));


-- ============================================================
-- STEP 8. RPC — RLS 를 우회하지 않고 프론트 동작을 성립시키는 함수들
-- ============================================================

-- [RLS-1] 초대 코드로 팀 참여
--   teams_select 는 is_active 인 팀만 보여준다. 비공개(모집중) 팀은 코드를 알아도
--   조회 자체가 안 되므로 클라이언트에서 코드 → 팀 조회가 불가능하다.
--   정책을 넓히면 비공개 팀이 전부 노출되므로 security definer 함수로만 뚫는다.
create or replace function join_team_by_code(p_code text)
returns uuid language plpgsql security definer
set search_path = public as $$
declare
  v_team teams%rowtype;
begin
  if not is_account_active() then
    raise exception '이용이 제한된 계정입니다';
  end if;

  select * into v_team from teams
  where invite_code = upper(trim(p_code)) and is_active is not false;

  if not found then
    raise exception '초대 코드를 찾을 수 없습니다';
  end if;

  if exists (select 1 from team_members where team_id = v_team.id and user_id = auth.uid()) then
    raise exception '이미 참여한 팀입니다';
  end if;

  if v_team.filled_count >= v_team.capacity then
    raise exception '팀 정원이 가득 찼습니다';
  end if;

  -- 매칭이 성사된 팀에는 합류할 수 없다 (프론트 joinTeamByCode 의 MATCHED 체크)
  if exists (
    select 1 from matches
    where status = 'accepted' and (from_team_id = v_team.id or to_team_id = v_team.id)
  ) then
    raise exception '이미 매칭이 성사된 팀입니다';
  end if;

  insert into team_members (team_id, user_id, is_owner) values (v_team.id, auth.uid(), false);
  return v_team.id;
end; $$;

revoke all on function join_team_by_code(text) from public;
grant execute on function join_team_by_code(text) to authenticated;


-- [RLS-2] 약속 확정/수정/취소
--   프론트 chat/[id].tsx 는 팀장이 아니어도 약속 잡기 버튼을 누를 수 있다.
--   matches_update 정책은 팀장만 허용하므로 팀원은 실패한다.
--   컬럼 단위 RLS 가 없으니 정책을 넓히면 팀원이 status 까지 바꿀 수 있게 된다.
--   → 약속만 바꾸는 전용 함수를 열어 준다.
create or replace function set_match_plan(
  p_match_id uuid,
  p_date date,
  p_time time,
  p_place text
)
returns void language plpgsql security definer
set search_path = public as $$
declare
  v_match matches%rowtype;
begin
  select * into v_match from matches where id = p_match_id;
  if not found then
    raise exception '매칭을 찾을 수 없습니다';
  end if;

  if not (is_team_member(v_match.from_team_id) or is_team_member(v_match.to_team_id)) then
    raise exception '이 매칭의 참여자가 아닙니다';
  end if;

  if v_match.status <> 'accepted' then
    raise exception '성사된 매칭에만 약속을 정할 수 있습니다';
  end if;

  update matches
  set plan_date = p_date, plan_time = p_time, plan_place = p_place
  where id = p_match_id;
end; $$;

revoke all on function set_match_plan(uuid, date, time, text) from public;
grant execute on function set_match_plan(uuid, date, time, text) to authenticated;


-- [RLS-3] 시스템 메시지 삽입
--   messages_insert 는 sender_id = auth.uid() 를 요구한다. 시스템 메시지는
--   sender_id 가 null 이라 클라이언트에서 넣을 수 없다(그게 맞다).
--   약속 확정·차단 안내 등 프론트가 appendSystemMessage() 로 뿌리던 문구는
--   이 함수로 남겨야 상대에게도 보인다.
create or replace function post_system_message(p_room_id uuid, p_text text)
returns uuid language plpgsql security definer
set search_path = public as $$
declare
  v_id uuid;
begin
  if not is_room_participant(p_room_id) then
    raise exception '이 채팅방의 참여자가 아닙니다';
  end if;

  insert into messages (room_id, sender_id, content, kind)
  values (p_room_id, null, p_text, 'system')
  returning id into v_id;

  return v_id;
end; $$;

revoke all on function post_system_message(uuid, text) from public;
grant execute on function post_system_message(uuid, text) to authenticated;


-- ============================================================
-- STEP 9. 인덱스
-- ============================================================

create index if not exists idx_teams_campus on teams(campus) where is_active;
create index if not exists idx_teams_invite_code on teams(invite_code) where invite_code is not null;
create index if not exists idx_blocks_room on blocks(room_id) where room_id is not null;


-- ============================================================
-- STEP 10. (선택) 차단 시 채팅방 강제 종료 트리거 완화
--   기존 close_rooms_on_block 은 한 명만 차단해도 방 전체가 닫힌다.
--   프론트는 차단한 사람의 말풍선만 가리고 대화는 계속하는 UX 다.
--   Apple 1.2 대응은 '차단 = 그 사용자 콘텐츠 미노출'로도 충족되므로
--   아래를 실행하면 프론트 동작과 일치시킬 수 있다. (판단 후 선택 실행)
--
--   drop trigger if exists blocks_close_rooms on blocks;
--
--   대신 메시지 노출은 아래 정책으로 막는다:
--   drop policy if exists messages_select on messages;
--   create policy messages_select on messages for select to authenticated
--   using (
--     (is_room_participant(room_id) and deleted_at is null
--      and (sender_id is null or not is_blocked_with(sender_id)))
--     or is_admin()
--   );
-- ============================================================
