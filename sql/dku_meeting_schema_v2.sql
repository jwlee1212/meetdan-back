-- ============================================================
-- 단국대 미팅앱 — Supabase 스키마 v2 (프론트엔드 기준 재설계)
--
-- 설계 기준: meetdan-front
--   store/useStore.ts   — Team / RequestData / Match / Report / BlockedUser / CurrentUser
--   utils/auth.ts       — Account / UserProfile
--   app/**              — 화면이 실제로 읽고 쓰는 값
--   components/ui/*     — 입력 길이 제한(PLACE_MAX, DETAIL_MAX, BIO_MAX …)
--
-- v1(dku_meeting_schema.sql) 대비 핵심 변경 3가지
--   1) posts 테이블 제거 → teams 하나로 통합. 프론트의 Team 이 곧 게시글이다.
--   2) enum 값을 프론트 리터럴 그대로 사용 ('M'/'F', '죽전', 'ACTIVE', 'WAITING' …).
--      TS ↔ DB 매핑 레이어가 통째로 사라진다.
--   3) 확정 약속 / 초대 코드 / 캠퍼스 / 태그 / MBTI 등 프론트 전용 필드 정식 편입.
--
-- Edge Function 영향: 없음
--   verify-email   → profiles.email_verified_at (유지, email 컬럼만 같이 채우면 됨)
--   filter-message → messages.is_filtered / filter_note (유지)
--   delete-account → profiles.deleted_at / status (유지)
--
-- ⚠ 이 파일은 drop & recreate 다. 기존 데이터는 사라진다.
--   실행 순서: 0) 정리 → 1) 타입 → 2) 테이블 → 3) 헬퍼 → 4) RLS → 5) 트리거
--              → 6) RPC → 7) 뷰 → 8) 인덱스 → 9) Realtime
-- ============================================================


-- ============================================================
-- 0. 기존 객체 정리
-- ============================================================

drop view   if exists my_matches cascade;

drop table  if exists banned_words cascade;
drop table  if exists admins       cascade;
drop table  if exists reports      cascade;
drop table  if exists blocks       cascade;
drop table  if exists messages     cascade;
drop table  if exists chat_rooms   cascade;
drop table  if exists matches      cascade;
drop table  if exists posts        cascade;   -- v2에서 teams 로 통합
drop table  if exists team_members cascade;
drop table  if exists teams        cascade;
drop table  if exists profiles     cascade;

drop type   if exists gender_t       cascade;
drop type   if exists campus_t       cascade;
drop type   if exists account_status cascade;
drop type   if exists team_status    cascade;
drop type   if exists match_status   cascade;
drop type   if exists message_kind   cascade;
drop type   if exists report_target  cascade;
drop type   if exists report_reason  cascade;
drop type   if exists report_status  cascade;


-- ============================================================
-- 1. 타입 — 값은 전부 프론트 리터럴과 1:1
-- ============================================================

-- store/useStore.ts: gender: "M" | "F"
create type gender_t as enum ('M', 'F');

-- constants/departments.ts: export type Campus = "죽전" | "천안"
create type campus_t as enum ('죽전', '천안');

-- store/useStore.ts: Team["status"]
--   RECRUITING 모집중 / READY 인원 다 참(비공개) / ACTIVE 게시판 공개중 / MATCHED 매칭 성사
--   v1의 "FULL" 은 프론트 어디서도 생성되지 않아 제외했다. TS 타입에서도 지울 것.
create type team_status as enum ('RECRUITING', 'READY', 'ACTIVE', 'MATCHED');

-- store/useStore.ts: RequestData["status"]
--   프론트에 신청 취소 UI 가 없어 'CANCELLED' 는 넣지 않았다.
create type match_status as enum ('WAITING', 'ACCEPTED', 'REJECTED');

-- app/chat/[id].tsx: Message.sender("system") + Message.type("proposal")
create type message_kind as enum ('user', 'system', 'proposal');

-- store/useStore.ts: ReportTargetType = "USER" | "ROOM"
create type report_target as enum ('USER', 'ROOM');

-- store/useStore.ts: REPORT_REASONS 6종
create type report_reason as enum ('ABUSE', 'SEXUAL', 'SPAM', 'FRAUD', 'NO_SHOW', 'ETC');

-- 아래 둘은 프론트 UI가 없는 운영 전용. Apple 심사/제재 처리에 필요해 유지한다.
create type account_status as enum ('active', 'warned', 'suspended', 'deleted');
create type report_status  as enum ('pending', 'resolved', 'dismissed');


-- ============================================================
-- 2. 테이블
-- ============================================================

-- ------------------------------------------------------------
-- 2-1. profiles
--   CurrentUser(store) + Account(가입 확정, 읽기 전용) + UserProfile(마이 탭 편집)
--   세 가지가 프론트에서 분리돼 있을 뿐 실체는 하나다. 여기서 합친다.
-- ------------------------------------------------------------

create table profiles (
  id          uuid primary key references auth.users(id) on delete cascade,

  -- ── 가입 시 확정, 이후 변경 불가 (utils/auth.ts: Account) ──
  login_id    text not null unique                       -- signupScreen 의 userId
              check (char_length(login_id) between 2 and 20),
  name        text not null                              -- 실명
              check (char_length(name) between 1 and 20),
  email       text not null unique                       -- 마이 탭이 그대로 노출한다
              check (email ~* '^[a-zA-Z0-9._%+-]+@dankook\.ac\.kr$'),
  gender      gender_t not null,
  campus      campus_t not null,                         -- 홈 탭 기본 필터의 기준값
  dept        text not null,                             -- v1의 department. 프론트 이름을 따른다

  -- ── 마이 탭에서 언제든 바꾸는 값 (utils/auth.ts: UserProfile) ──
  nickname    text                                       -- 비우면 name 으로 대체 표시
              check (nickname is null or char_length(nickname) between 1 and 12),
  bio         text check (bio is null or char_length(bio) <= 40),   -- profile.tsx BIO_MAX
  mbti        text check (mbti is null or mbti ~ '^[EI][SN][TF][JP]$'),
  avatar_idx  int not null default 0                     -- assets/images/profile_avatars 인덱스
              check (avatar_idx between 0 and 11),

  -- ── 운영 (프론트 UI 없음. Edge Function / 관리자용) ──
  email_verified_at timestamptz,                         -- verify-email 이 기록
  status            account_status not null default 'active',
  strike_count      int not null default 0,
  suspended_until   timestamptz,
  deleted_at        timestamptz,                         -- delete-account 가 기록

  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on column profiles.dept is
  'constants/departments.ts 의 학과명 문자열. 단과대는 findCollegeByDept() 로 역산 가능해 저장하지 않는다.';


-- ------------------------------------------------------------
-- 2-2. teams  (v1의 teams + posts 통합)
--   프론트 Team 하나가 팀이자 모집 게시글이다.
--   게시판 = teams where status = 'ACTIVE'  ← app/(tabs)/index.tsx 와 정확히 일치
-- ------------------------------------------------------------

create table teams (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references profiles(id) on delete cascade,

  title         text not null check (char_length(title) between 2 and 50),
  content       text not null check (char_length(content) <= 1000),

  campus        campus_t not null,
  dept          text not null,                 -- 팀 대표 학과 (생성자 학과에서 가져옴)
  gender        gender_t not null,             -- 과팅이므로 팀은 동성으로 구성
  avg_age       int not null check (avg_age between 18 and 40),
  tags          text[] not null default '{}',

  -- Team.count. write.tsx 는 2~4를 제공하지만 여유를 둔다.
  capacity      int not null check (capacity between 2 and 6),
  -- Team.currentCount. team_members 를 매번 세면 목록이 N+1 이 되어 캐시한다(트리거 유지).
  filled_count  int not null default 0 check (filled_count >= 0),

  status        team_status not null default 'RECRUITING',

  -- my_team.tsx 의 '코드로 참여'. 6자리 영대문자+숫자.
  invite_code   text unique check (invite_code ~ '^[A-Z0-9]{6}$'),

  created_at    timestamptz not null default now(),

  check (filled_count <= capacity)
);


create table team_members (
  team_id    uuid not null references teams(id) on delete cascade,
  user_id    uuid not null references profiles(id) on delete cascade,
  -- Team.members[].role: "LEADER" | "MEMBER"
  is_owner   boolean not null default false,
  joined_at  timestamptz not null default now(),

  primary key (team_id, user_id)
);

-- 프론트는 한 사람이 여러 팀에 속하는 걸 허용한다
-- (post/[id].tsx 가 "어떤 팀으로 신청할까요?" 로 팀을 고르게 한다). 제약을 걸지 않는다.


-- ------------------------------------------------------------
-- 2-3. matches — 신청서(RequestData)와 매칭(Match)을 한 테이블로
--   WAITING  → sentRequests / receivedRequests
--   ACCEPTED → matches (+ chat_rooms 자동 생성)
--   REJECTED → 거절된 신청
--   프론트가 둘을 나눠 들고 있는 건 mock store 사정이고, 실체는 한 줄의 상태 변화다.
-- ------------------------------------------------------------

create table matches (
  id            uuid primary key default gen_random_uuid(),
  from_team_id  uuid not null references teams(id) on delete cascade,  -- senderTeamId
  to_team_id    uuid not null references teams(id) on delete cascade,  -- receiverTeamId
  status        match_status not null default 'WAITING',

  -- Match.confirmedPlan. 매칭 1건당 약속 1건이라 별도 테이블로 빼지 않는다.
  plan_date     date,                                    -- "YYYY-MM-DD"
  plan_time     time,                                    -- "HH:mm"
  plan_place    text check (plan_place is null or char_length(plan_place) <= 30), -- PLACE_MAX

  created_at    timestamptz not null default now(),
  responded_at  timestamptz,                             -- Match.startedAt

  check (from_team_id <> to_team_id),
  -- PlanSheet 는 날짜·시간을 항상 함께 넘긴다. 장소는 비어 있을 수 있다.
  check (
    (plan_date is null and plan_time is null)
    or (plan_date is not null and plan_time is not null)
  )
);

-- 같은 팀 조합으로 대기중 신청 중복 방지 (sendMatchRequest 의 alreadySent 검사)
create unique index matches_no_duplicate_waiting
  on matches(from_team_id, to_team_id)
  where status = 'WAITING';


-- ------------------------------------------------------------
-- 2-4. 채팅
-- ------------------------------------------------------------

create table chat_rooms (
  id           uuid primary key default gen_random_uuid(),
  match_id     uuid not null unique references matches(id) on delete cascade,
  created_at   timestamptz not null default now(),
  closed_at    timestamptz,                              -- 종료 제안 합의 시 기록
  close_reason text
);

create table messages (
  id          uuid primary key default gen_random_uuid(),
  room_id     uuid not null references chat_rooms(id) on delete cascade,

  -- 시스템 메시지·종료 제안 카드는 보낸 사람이 없다
  sender_id   uuid references profiles(id) on delete cascade,
  kind        message_kind not null default 'user',
  content     text not null check (char_length(content) <= 2000),

  -- ProposalCard 의 결정 (동의 / 더 대화할래요)
  proposal_result text check (proposal_result in ('ACCEPT', 'REJECT')),

  -- filter-message Edge Function 이 기록
  is_filtered boolean not null default false,
  filter_note text,

  -- 신고 처리로 삭제된 메시지 (감사 추적용 soft delete)
  deleted_at  timestamptz,
  deleted_by  uuid references profiles(id),

  created_at  timestamptz not null default now(),

  check ((kind = 'user') = (sender_id is not null)),
  check (proposal_result is null or kind = 'proposal')
);


-- ------------------------------------------------------------
-- 2-5. 차단 (Apple Guideline 1.2)
--   blocked_name / blocked_dept 는 차단 시점 스냅샷이다.
--   profiles_select 가 차단 상대를 가리기 때문에, 이게 없으면
--   app/settings/blocked.tsx 가 이름 없는 빈 목록이 된다.
-- ------------------------------------------------------------

create table blocks (
  blocker_id   uuid not null references profiles(id) on delete cascade,
  blocked_id   uuid not null references profiles(id) on delete cascade,
  room_id      uuid references chat_rooms(id) on delete set null,   -- BlockedUser.roomId

  blocked_name text,                                     -- BlockedUser.name
  blocked_dept text,                                     -- BlockedUser.dept

  created_at   timestamptz not null default now(),       -- BlockedUser.blockedAt

  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);


-- ------------------------------------------------------------
-- 2-6. 신고 & 제재
-- ------------------------------------------------------------

create table reports (
  id             uuid primary key default gen_random_uuid(),
  reporter_id    uuid references profiles(id) on delete set null,

  target_type    report_target not null,                 -- 'USER' | 'ROOM'
  target_id      uuid not null,                          -- 다형 참조(FK 없음)
  target_user_id uuid references profiles(id) on delete cascade,  -- 제재 대상
  room_id        uuid references chat_rooms(id) on delete set null,  -- Report.roomId

  reason         report_reason not null,
  detail         text check (detail is null or char_length(detail) <= 200),  -- DETAIL_MAX

  status         report_status not null default 'pending',
  action_taken   text,
  resolved_at    timestamptz,
  resolved_by    uuid references profiles(id),

  created_at     timestamptz not null default now()
);

-- submitReport() 의 중복 접수 거부를 서버에서도 강제
create unique index reports_no_duplicate
  on reports(reporter_id, target_type, target_id,
             coalesce(room_id, '00000000-0000-0000-0000-000000000000'::uuid));


create table admins (
  user_id    uuid primary key references profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- filter-message Edge Function 이 참조
create table banned_words (
  word       text primary key,
  severity   int not null default 1 check (severity between 1 and 3),
  -- 1: 마스킹, 2: 전송 차단, 3: 전송 차단 + 자동 신고 생성
  created_at timestamptz not null default now()
);


-- ============================================================
-- 3. 헬퍼 함수
--    RLS 정책 안에서 다른 테이블을 조회하면 그 테이블의 RLS도 같이 걸려
--    무한 재귀나 오탐이 생긴다. security definer 로 감싼다.
-- ============================================================

create or replace function is_admin()
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid());
$$;

create or replace function is_team_member(p_team_id uuid)
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (
    select 1 from team_members
    where team_id = p_team_id and user_id = auth.uid()
  );
$$;

create or replace function is_team_owner(p_team_id uuid)
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (
    select 1 from team_members
    where team_id = p_team_id and user_id = auth.uid() and is_owner
  );
$$;

create or replace function is_blocked_with(p_user_id uuid)
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (
    select 1 from blocks
    where (blocker_id = auth.uid() and blocked_id = p_user_id)
       or (blocker_id = p_user_id  and blocked_id = auth.uid())
  );
$$;

create or replace function is_blocked_with_team(p_team_id uuid)
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (
    select 1
    from team_members tm
    join blocks b
      on (b.blocker_id = auth.uid()  and b.blocked_id = tm.user_id)
      or (b.blocker_id = tm.user_id  and b.blocked_id = auth.uid())
    where tm.team_id = p_team_id
  );
$$;

-- ⭐ v2 신규. 매칭이 성사되면 두 팀 모두 status='MATCHED' 가 되어 게시판에서 내려간다.
--    그런데 채팅 헤더·활동 탭·상대팀 프로필은 그 뒤로도 상대 팀 정보를 계속 읽는다.
--    (프론트가 matchedTeams 보관함을 따로 들고 있던 이유가 바로 이것)
--    이 함수로 teams_select 를 열어 주면 보관함 자체가 필요 없어진다.
create or replace function is_matched_with_team(p_team_id uuid)
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (
    select 1 from matches m
    where m.status = 'ACCEPTED'
      and (
        (m.from_team_id = p_team_id and exists (
           select 1 from team_members tm where tm.team_id = m.to_team_id   and tm.user_id = auth.uid()))
        or
        (m.to_team_id   = p_team_id and exists (
           select 1 from team_members tm where tm.team_id = m.from_team_id and tm.user_id = auth.uid()))
      )
  );
$$;

create or replace function is_room_participant(p_room_id uuid)
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (
    select 1
    from chat_rooms r
    join matches m       on m.id = r.match_id
    join team_members tm on tm.team_id in (m.from_team_id, m.to_team_id)
    where r.id = p_room_id and tm.user_id = auth.uid()
  );
$$;

create or replace function is_room_open(p_room_id uuid)
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (select 1 from chat_rooms where id = p_room_id and closed_at is null);
$$;

create or replace function is_account_active()
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (
    select 1 from profiles
    where id = auth.uid()
      and status in ('active', 'warned')
      and deleted_at is null
      and email_verified_at is not null
  );
$$;


-- ============================================================
-- 4. RLS 정책
--    profiles / blocks / reports 는 v1과 의미가 동일하다(재검증 부담 최소).
--    teams 는 posts 통합으로 새로 쓰고, messages 는 차단 필터가 추가됐다.
-- ============================================================

alter table profiles     enable row level security;
alter table teams        enable row level security;
alter table team_members enable row level security;
alter table matches      enable row level security;
alter table chat_rooms   enable row level security;
alter table messages     enable row level security;
alter table blocks       enable row level security;
alter table reports      enable row level security;
alter table admins       enable row level security;
alter table banned_words enable row level security;

-- ---------- profiles (v1과 동일) ----------
create policy profiles_select on profiles for select to authenticated
using (
  id = auth.uid()
  or is_admin()
  or (deleted_at is null and status <> 'suspended' and not is_blocked_with(id))
);

create policy profiles_insert on profiles for insert to authenticated
with check (id = auth.uid());

create policy profiles_update on profiles for update to authenticated
using (id = auth.uid() or is_admin())
with check (id = auth.uid() or is_admin());

-- ---------- teams ----------
-- 게시판 노출은 status='ACTIVE' 하나로 결정된다 (v1의 teams.is_active + posts.is_active 통합).
-- 차단한 상대의 팀은 목록에서 자동으로 사라진다.
create policy teams_select on teams for select to authenticated
using (
  is_admin()
  or is_team_member(id)
  or is_matched_with_team(id)
  or (status = 'ACTIVE' and not is_blocked_with_team(id))
);

create policy teams_insert on teams for insert to authenticated
with check (owner_id = auth.uid() and is_account_active());

create policy teams_update on teams for update to authenticated
using (is_team_owner(id) or is_admin())
with check (is_team_owner(id) or is_admin());

create policy teams_delete on teams for delete to authenticated
using (is_team_owner(id) or is_admin());

-- ---------- team_members ----------
create policy team_members_select on team_members for select to authenticated
using (is_team_member(team_id) or is_matched_with_team(team_id) or is_admin());

create policy team_members_insert on team_members for insert to authenticated
with check (user_id = auth.uid() and is_account_active());

create policy team_members_delete on team_members for delete to authenticated
using (user_id = auth.uid() or is_team_owner(team_id) or is_admin());

-- ---------- matches ----------
create policy matches_select on matches for select to authenticated
using (is_team_member(from_team_id) or is_team_member(to_team_id) or is_admin());

-- 차단 관계인 팀에는 신청 자체가 불가
create policy matches_insert on matches for insert to authenticated
with check (
  is_team_owner(from_team_id)
  and is_account_active()
  and not is_blocked_with_team(to_team_id)
  and status = 'WAITING'
);

-- 받는 쪽이 수락/거절. 수락 시 뒷처리는 아래 트리거가 전부 맡는다.
-- ⚠ 약속(plan_*)은 이 정책으로 팀장만 수정 가능하다. 팀원도 잡게 하려면
--    set_match_plan() RPC 를 쓴다 (6. RPC 참고).
create policy matches_update on matches for update to authenticated
using (is_team_owner(to_team_id) or is_team_owner(from_team_id) or is_admin());

-- ---------- chat_rooms ----------
create policy chat_rooms_select on chat_rooms for select to authenticated
using (is_room_participant(id) or is_admin());

create policy chat_rooms_update on chat_rooms for update to authenticated
using (is_room_participant(id) or is_admin());

-- ---------- messages ----------
-- ⭐ v2: 차단한 상대의 메시지는 아예 내려오지 않는다.
--    프론트 chat/[id].tsx 는 "차단한 사용자의 메시지예요" 자리표시자를 그리는데,
--    내용 자체가 클라이언트에 도달하지 않아야 진짜 차단이다.
create policy messages_select on messages for select to authenticated
using (
  (
    is_room_participant(room_id)
    and deleted_at is null
    and (sender_id is null or not is_blocked_with(sender_id))
  )
  or is_admin()
);

create policy messages_insert on messages for insert to authenticated
with check (
  sender_id = auth.uid()
  and kind = 'user'                    -- system/proposal 은 RPC 로만 (6. RPC 참고)
  and is_room_participant(room_id)
  and is_room_open(room_id)
  and is_account_active()
);

create policy messages_update on messages for update to authenticated
using (sender_id = auth.uid() or is_admin());

-- ---------- blocks (v1과 동일) ----------
create policy blocks_select on blocks for select to authenticated
using (blocker_id = auth.uid() or is_admin());

create policy blocks_insert on blocks for insert to authenticated
with check (blocker_id = auth.uid());

create policy blocks_delete on blocks for delete to authenticated
using (blocker_id = auth.uid());

-- ---------- reports (v1과 동일) ----------
create policy reports_select on reports for select to authenticated
using (reporter_id = auth.uid() or is_admin());

create policy reports_insert on reports for insert to authenticated
with check (reporter_id = auth.uid());

create policy reports_update on reports for update to authenticated
using (is_admin());

-- ---------- admins / banned_words ----------
create policy admins_select on admins for select to authenticated
using (is_admin());

create policy banned_words_select on banned_words for select to authenticated
using (is_admin());


-- ============================================================
-- 5. 트리거
-- ============================================================

-- ---------- updated_at ----------
create or replace function touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end; $$;

create trigger profiles_touch before update on profiles
for each row execute function touch_updated_at();


-- ---------- 팀 생성 시 owner 자동 등록 ----------
create or replace function add_owner_to_team()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  insert into team_members (team_id, user_id, is_owner)
  values (new.id, new.owner_id, true);
  return new;
end; $$;

create trigger teams_add_owner after insert on teams
for each row execute function add_owner_to_team();


-- ---------- 인원 수 캐시 + 상태 자동 전이 ----------
-- 프론트 규칙 그대로: 인원이 다 차면 READY, 아니면 RECRUITING.
-- 단 공개중(ACTIVE)이거나 매칭된(MATCHED) 팀의 상태는 인원 변동으로 바뀌지 않는다.
create or replace function sync_team_fill()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_team_id uuid := coalesce(new.team_id, old.team_id);
  v_count   int;
  v_cap     int;
  v_status  team_status;
begin
  select count(*) into v_count from team_members where team_id = v_team_id;
  select capacity, status into v_cap, v_status from teams where id = v_team_id;

  if not found then
    return coalesce(new, old);   -- 팀이 이미 삭제된 경우(cascade)
  end if;

  update teams
  set filled_count = v_count,
      status = case
        when v_status in ('ACTIVE', 'MATCHED') then v_status
        when v_count >= v_cap                  then 'READY'::team_status
        else                                        'RECRUITING'::team_status
      end
  where id = v_team_id;

  return coalesce(new, old);
end; $$;

create trigger team_members_sync_fill
after insert or delete on team_members
for each row execute function sync_team_fill();


-- ---------- 정원 초과 방지 ----------
create or replace function assert_team_not_full()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_cap    int;
  v_filled int;
  v_status team_status;
begin
  select capacity, filled_count, status
  into v_cap, v_filled, v_status
  from teams where id = new.team_id for update;

  if v_status = 'MATCHED' then
    raise exception '이미 매칭이 성사된 팀입니다' using errcode = 'check_violation';
  end if;

  if v_filled >= v_cap then
    raise exception '팀 정원이 가득 찼습니다' using errcode = 'check_violation';
  end if;

  return new;
end; $$;

create trigger team_members_capacity_guard
before insert on team_members
for each row execute function assert_team_not_full();


-- ---------- 매칭 수락 뒷처리 ----------
-- 프론트 acceptMatch() 가 하던 일을 전부 서버로 옮긴다.
--   1) responded_at 기록
--   2) 채팅방 생성
--   3) 두 팀을 MATCHED 로 (게시판에서 내려감)
--   4) 두 팀에 걸려 있던 나머지 대기중 신청을 자동 거절
create or replace function on_match_accepted()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  if new.status = 'ACCEPTED' and old.status = 'WAITING' then
    -- 수락 권한은 '받는 팀'의 팀장에게만 있다 (정책만으로는 방향을 구분할 수 없다)
    if not (is_team_owner(new.to_team_id) or is_admin()) then
      raise exception '신청을 받은 팀의 팀장만 수락할 수 있습니다';
    end if;

    new.responded_at = now();

    insert into chat_rooms (match_id) values (new.id)
    on conflict (match_id) do nothing;

    update teams set status = 'MATCHED'
    where id in (new.from_team_id, new.to_team_id);

    update matches
    set status = 'REJECTED', responded_at = now()
    where status = 'WAITING'
      and id <> new.id
      and (from_team_id in (new.from_team_id, new.to_team_id)
        or to_team_id   in (new.from_team_id, new.to_team_id));

  elsif new.status = 'REJECTED' and old.status = 'WAITING' then
    new.responded_at = now();
  end if;

  return new;
end; $$;

create trigger matches_on_accepted before update on matches
for each row execute function on_match_accepted();


-- ---------- 차단 시 프로필 스냅샷 ----------
-- profiles_select 가 차단 상대를 가리므로, 차단 목록 화면이 쓸 값을 이때 복사해 둔다.
create or replace function snapshot_blocked_profile()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  select coalesce(nullif(nickname, ''), name), dept
  into new.blocked_name, new.blocked_dept
  from profiles where id = new.blocked_id;
  return new;
end; $$;

create trigger blocks_snapshot before insert on blocks
for each row execute function snapshot_blocked_profile();

-- ⚠ v1의 close_rooms_on_block 트리거는 제거했다.
--    한 명만 차단해도 팀 전체와의 채팅방이 닫혀서 프론트 UX(해당 사용자 메시지만
--    가리고 대화는 계속)와 충돌했다. 차단 요건은 위 messages_select 정책이
--    "차단한 상대의 메시지는 내려주지 않는다"로 충족한다.


-- ---------- 신고 확정 시 누적 제재 ----------
-- raw 신고 수로 세면 조직적 허위신고에 취약해서 관리자 확정 건만 카운트한다.
create or replace function apply_strike_on_report()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_count int;
begin
  if new.status = 'resolved' and old.status <> 'resolved' and new.target_user_id is not null then
    update profiles
    set strike_count = strike_count + 1
    where id = new.target_user_id
    returning strike_count into v_count;

    if v_count >= 5 then
      update profiles
      set status = 'suspended', suspended_until = now() + interval '30 days'
      where id = new.target_user_id;
    elsif v_count >= 3 then
      update profiles set status = 'warned' where id = new.target_user_id;
    end if;

    new.resolved_at = now();
  end if;
  return new;
end; $$;

create trigger reports_apply_strike before update on reports
for each row execute function apply_strike_on_report();


-- ============================================================
-- 6. RPC — RLS를 넓히지 않고 프론트 동작을 성립시키는 통로
-- ============================================================

-- ---------- 초대 코드로 팀 참여 ----------
-- teams_select 는 ACTIVE 팀만 보여준다. 초대 코드로 들어갈 팀은 대개 비공개(RECRUITING)라
-- 클라이언트에서 코드 → 팀 조회가 불가능하다. 정책을 넓히면 비공개 팀이 전부 노출되므로
-- 이 함수로만 뚫는다. 프론트 joinTeamByCode() 의 검사 순서를 그대로 옮겼다.
create or replace function join_team_by_code(p_code text)
returns uuid language plpgsql security definer
set search_path = public as $$
declare
  v_team teams%rowtype;
begin
  if not is_account_active() then
    raise exception '이용이 제한된 계정입니다';
  end if;

  select * into v_team from teams where invite_code = upper(trim(p_code));

  if not found then
    raise exception '초대 코드를 찾을 수 없습니다';
  end if;

  if exists (select 1 from team_members where team_id = v_team.id and user_id = auth.uid()) then
    raise exception '이미 참여한 팀입니다';
  end if;

  -- 정원·MATCHED 검사는 team_members_capacity_guard 트리거가 다시 한 번 막는다
  insert into team_members (team_id, user_id, is_owner) values (v_team.id, auth.uid(), false);
  return v_team.id;
end; $$;

revoke all on function join_team_by_code(text) from public;
grant execute on function join_team_by_code(text) to authenticated;


-- ---------- 약속 확정 / 수정 / 취소 ----------
-- chat/[id].tsx 의 약속 잡기 버튼은 팀장이 아니어도 눌린다.
-- matches_update 정책은 팀장만 허용하고, Postgres RLS 는 컬럼 단위가 없어
-- 정책을 넓히면 팀원이 status(수락/거절)까지 바꿀 수 있다. 약속만 여는 통로.
create or replace function set_match_plan(
  p_match_id uuid,
  p_date     date,
  p_time     time,
  p_place    text
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

  if v_match.status <> 'ACCEPTED' then
    raise exception '성사된 매칭에만 약속을 정할 수 있습니다';
  end if;

  update matches
  set plan_date = p_date, plan_time = p_time, plan_place = p_place
  where id = p_match_id;
end; $$;

revoke all on function set_match_plan(uuid, date, time, text) from public;
grant execute on function set_match_plan(uuid, date, time, text) to authenticated;


-- ---------- 시스템 메시지 ----------
-- messages_insert 는 sender_id = auth.uid() and kind='user' 를 요구한다.
-- 지금 프론트의 appendSystemMessage() 는 로컬 state 에만 쌓여 상대에게 안 보인다.
-- 약속 확정·차단 안내 등은 이 함수로 남겨야 양쪽에 뜬다.
create or replace function post_system_message(p_room_id uuid, p_text text)
returns uuid language plpgsql security definer
set search_path = public as $$
declare
  v_id uuid;
begin
  if not is_room_participant(p_room_id) then
    raise exception '이 채팅방의 참여자가 아닙니다';
  end if;

  insert into messages (room_id, sender_id, kind, content)
  values (p_room_id, null, 'system', p_text)
  returning id into v_id;

  return v_id;
end; $$;

revoke all on function post_system_message(uuid, text) from public;
grant execute on function post_system_message(uuid, text) to authenticated;


-- ---------- 채팅 종료 제안 ----------
create or replace function post_exit_proposal(p_room_id uuid)
returns uuid language plpgsql security definer
set search_path = public as $$
declare
  v_id uuid;
begin
  if not is_room_participant(p_room_id) then
    raise exception '이 채팅방의 참여자가 아닙니다';
  end if;

  insert into messages (room_id, sender_id, kind, content)
  values (p_room_id, null, 'proposal', '채팅 종료 제안')
  returning id into v_id;

  return v_id;
end; $$;

create or replace function resolve_exit_proposal(p_message_id uuid, p_result text)
returns void language plpgsql security definer
set search_path = public as $$
declare
  v_room_id uuid;
begin
  if p_result not in ('ACCEPT', 'REJECT') then
    raise exception '잘못된 값입니다';
  end if;

  select room_id into v_room_id from messages
  where id = p_message_id and kind = 'proposal' and proposal_result is null;

  if not found then
    raise exception '처리할 종료 제안이 없습니다';
  end if;

  if not is_room_participant(v_room_id) then
    raise exception '이 채팅방의 참여자가 아닙니다';
  end if;

  update messages set proposal_result = p_result where id = p_message_id;

  if p_result = 'ACCEPT' then
    update chat_rooms
    set closed_at = now(), close_reason = 'exit_agreed'
    where id = v_room_id and closed_at is null;
  end if;
end; $$;

revoke all on function post_exit_proposal(uuid)            from public;
revoke all on function resolve_exit_proposal(uuid, text)   from public;
grant execute on function post_exit_proposal(uuid)          to authenticated;
grant execute on function resolve_exit_proposal(uuid, text) to authenticated;


-- ============================================================
-- 7. 뷰 — 화면이 필요로 하는 '내 시점' 데이터
-- ============================================================

-- history.tsx(매칭 탭)와 chat/[id].tsx 헤더가 쓰는 모양 그대로.
-- 프론트 Match 는 myTeamId / partnerTeamId 가 보는 사람 기준이라 여기서 뒤집어 준다.
-- security_invoker=true → 조회자의 RLS가 그대로 적용된다.
create view my_matches with (security_invoker = true) as
select
  m.id            as match_id,
  r.id            as room_id,
  case when is_team_member(m.from_team_id) then m.from_team_id else m.to_team_id   end as my_team_id,
  case when is_team_member(m.from_team_id) then m.to_team_id   else m.from_team_id end as partner_team_id,
  pt.title        as partner_team_name,
  pt.dept         as partner_team_dept,
  pt.capacity     as partner_team_count,
  m.responded_at  as started_at,
  m.plan_date,
  m.plan_time,
  m.plan_place,
  r.closed_at
from matches m
join chat_rooms r on r.match_id = m.id
join teams pt
  on pt.id = case when is_team_member(m.from_team_id) then m.to_team_id else m.from_team_id end
where m.status = 'ACCEPTED';


-- ============================================================
-- 8. 인덱스
-- ============================================================

create index idx_teams_board        on teams(created_at desc) where status = 'ACTIVE';
create index idx_teams_campus       on teams(campus, status);
create index idx_teams_owner        on teams(owner_id);
create index idx_team_members_user  on team_members(user_id);
create index idx_matches_to_team    on matches(to_team_id, status);
create index idx_matches_from_team  on matches(from_team_id, status);
create index idx_matches_plan       on matches(plan_date) where status = 'ACCEPTED' and plan_date is not null;
create index idx_messages_room      on messages(room_id, created_at desc);
create index idx_blocks_blocked     on blocks(blocked_id);
create index idx_reports_pending    on reports(created_at desc) where status = 'pending';
create index idx_profiles_status    on profiles(status) where deleted_at is null;


-- ============================================================
-- 9. Realtime (채팅 / 신청 알림)
-- ============================================================

alter publication supabase_realtime add table messages;
alter publication supabase_realtime add table matches;
