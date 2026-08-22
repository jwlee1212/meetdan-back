-- ============================================================
-- 단국대 미팅앱 — Supabase 스키마 + RLS 정책 초안
-- 실행 순서: 1) 테이블 → 2) 헬퍼 함수 → 3) RLS 정책 → 4) 트리거 → 5) 인덱스
-- Supabase Dashboard > SQL Editor 에 통째로 붙여넣어 실행 가능
-- ============================================================


-- ============================================================
-- 0. 공통 타입
-- ============================================================

create type gender_t        as enum ('male', 'female');
create type account_status  as enum ('active', 'warned', 'suspended', 'deleted');
create type match_status    as enum ('pending', 'accepted', 'rejected', 'cancelled');
create type report_target   as enum ('user', 'team', 'post', 'message');
create type report_status   as enum ('pending', 'resolved', 'dismissed');


-- ============================================================
-- 1. 프로필 (auth.users 확장)
--    auth.users 는 Supabase가 관리. 여기엔 앱 고유 정보만.
-- ============================================================

create table profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  nickname      text not null check (char_length(nickname) between 2 and 12),
  gender        gender_t not null,
  birth_year    int check (birth_year between 1980 and 2015),
  department    text,                          -- 학과
  bio           text check (char_length(bio) <= 300),
  avatar_url    text,

  -- 학교 이메일 인증 결과 (Edge Function이 회원가입 시 기록)
  email_verified_at timestamptz,

  status        account_status not null default 'active',
  strike_count  int not null default 0,        -- 확정 신고 누적 횟수
  suspended_until timestamptz,

  -- 탈퇴 처리용 (Apple 5.1.1(v))
  deleted_at    timestamptz,

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);


-- ============================================================
-- 2. 팀
-- ============================================================

create table teams (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 1 and 20),
  gender      gender_t not null,               -- 팀 성별 (미팅은 보통 동성 팀끼리 구성)
  owner_id    uuid not null references profiles(id) on delete cascade,
  intro       text check (char_length(intro) <= 500),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table team_members (
  team_id    uuid not null references teams(id) on delete cascade,
  user_id    uuid not null references profiles(id) on delete cascade,
  is_owner   boolean not null default false,
  joined_at  timestamptz not null default now(),
  primary key (team_id, user_id)
);

-- 한 사람이 동시에 여러 팀에 속하는 걸 막고 싶으면 아래 주석 해제
-- create unique index team_members_one_active_team on team_members(user_id);


-- ============================================================
-- 3. 게시글 (팀이 올리는 매칭 모집글)
-- ============================================================

create table posts (
  id          uuid primary key default gen_random_uuid(),
  team_id     uuid not null references teams(id) on delete cascade,
  title       text not null check (char_length(title) between 2 and 50),
  content     text not null check (char_length(content) <= 1000),
  member_count int not null check (member_count between 1 and 6),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);


-- ============================================================
-- 4. 매칭 (팀 → 팀 신청)
-- ============================================================

create table matches (
  id            uuid primary key default gen_random_uuid(),
  from_team_id  uuid not null references teams(id) on delete cascade,
  to_team_id    uuid not null references teams(id) on delete cascade,
  post_id       uuid references posts(id) on delete set null,
  status        match_status not null default 'pending',
  created_at    timestamptz not null default now(),
  responded_at  timestamptz,

  check (from_team_id <> to_team_id)
);

-- 같은 팀 조합으로 중복 신청 방지 (대기중인 건만)
create unique index matches_no_duplicate_pending
  on matches(from_team_id, to_team_id)
  where status = 'pending';


-- ============================================================
-- 5. 채팅
-- ============================================================

create table chat_rooms (
  id         uuid primary key default gen_random_uuid(),
  match_id   uuid not null unique references matches(id) on delete cascade,
  created_at timestamptz not null default now(),
  closed_at  timestamptz,                      -- 차단/신고로 강제 종료 시 기록
  close_reason text
);

create table messages (
  id          uuid primary key default gen_random_uuid(),
  room_id     uuid not null references chat_rooms(id) on delete cascade,
  sender_id   uuid not null references profiles(id) on delete cascade,
  content     text not null check (char_length(content) <= 2000),

  -- 금칙어 필터 결과 (Edge Function이 기록)
  is_filtered boolean not null default false,
  filter_note text,

  -- 신고 처리로 삭제된 메시지 (감사 추적을 위해 soft delete)
  deleted_at  timestamptz,
  deleted_by  uuid references profiles(id),

  created_at  timestamptz not null default now()
);


-- ============================================================
-- 6. 차단 (Apple Guideline 1.2 필수)
-- ============================================================

create table blocks (
  blocker_id uuid not null references profiles(id) on delete cascade,
  blocked_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),

  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);


-- ============================================================
-- 7. 신고 & 제재
-- ============================================================

create table reports (
  id           uuid primary key default gen_random_uuid(),
  reporter_id  uuid not null references profiles(id) on delete set null,
  target_type  report_target not null,
  target_id    uuid not null,                  -- 다형 참조(FK 없음). 앱에서 타입별 조회
  target_user_id uuid references profiles(id) on delete cascade,  -- 제재 대상 유저

  reason       text not null,                  -- 사유 선택값 (욕설/성희롱/사칭/광고 등)
  detail       text check (char_length(detail) <= 1000),

  status       report_status not null default 'pending',
  action_taken text,                           -- '메시지 삭제', '계정 정지 7일' 등
  resolved_at  timestamptz,
  resolved_by  uuid references profiles(id),

  created_at   timestamptz not null default now()
);

-- 관리자 명단 (1인 개발이면 본인 uuid 하나만 넣으면 됨)
create table admins (
  user_id    uuid primary key references profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);


-- ============================================================
-- 8. 금칙어 사전 (Edge Function이 참조)
-- ============================================================

create table banned_words (
  word       text primary key,
  severity   int not null default 1 check (severity between 1 and 3),
  -- 1: 마스킹, 2: 전송 차단, 3: 전송 차단 + 자동 신고 생성
  created_at timestamptz not null default now()
);


-- ============================================================
-- 9. 헬퍼 함수
--    RLS 정책 안에서 다른 테이블을 조회하면 그 테이블의 RLS도 같이 걸려서
--    무한 재귀나 오탐이 생김. security definer 함수로 감싸는 게 정석.
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

-- 나와 특정 유저 사이에 차단 관계가 있는지 (양방향)
create or replace function is_blocked_with(p_user_id uuid)
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (
    select 1 from blocks
    where (blocker_id = auth.uid() and blocked_id = p_user_id)
       or (blocker_id = p_user_id  and blocked_id = auth.uid())
  );
$$;

-- 나와 특정 팀의 구성원 중 누구라도 차단 관계가 있는지
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

-- 내가 이 채팅방의 참여자인지
create or replace function is_room_participant(p_room_id uuid)
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (
    select 1
    from chat_rooms r
    join matches m     on m.id = r.match_id
    join team_members tm on tm.team_id in (m.from_team_id, m.to_team_id)
    where r.id = p_room_id and tm.user_id = auth.uid()
  );
$$;

-- 방이 아직 살아있는지 (전송 가능 여부)
create or replace function is_room_open(p_room_id uuid)
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (select 1 from chat_rooms where id = p_room_id and closed_at is null);
$$;

-- 내 계정이 정상 상태인지 (정지 중이면 쓰기 전부 차단)
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
-- 10. RLS 정책
-- ============================================================

alter table profiles     enable row level security;
alter table teams        enable row level security;
alter table team_members enable row level security;
alter table posts        enable row level security;
alter table matches      enable row level security;
alter table chat_rooms   enable row level security;
alter table messages     enable row level security;
alter table blocks       enable row level security;
alter table reports      enable row level security;
alter table admins       enable row level security;
alter table banned_words enable row level security;

-- ---------- profiles ----------
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
create policy teams_select on teams for select to authenticated
using (is_admin() or (is_active and not is_blocked_with_team(id)) or is_team_member(id));

create policy teams_insert on teams for insert to authenticated
with check (owner_id = auth.uid() and is_account_active());

create policy teams_update on teams for update to authenticated
using (is_team_owner(id) or is_admin());

create policy teams_delete on teams for delete to authenticated
using (is_team_owner(id) or is_admin());

-- ---------- team_members ----------
create policy team_members_select on team_members for select to authenticated
using (is_team_member(team_id) or is_admin());

create policy team_members_insert on team_members for insert to authenticated
with check (user_id = auth.uid() and is_account_active());

create policy team_members_delete on team_members for delete to authenticated
using (user_id = auth.uid() or is_team_owner(team_id) or is_admin());

-- ---------- posts ----------
-- 차단한 상대의 게시글은 매칭 후보 목록에서 자동으로 사라짐 (체크리스트 1번 차단 요건)
create policy posts_select on posts for select to authenticated
using (
  is_admin()
  or is_team_member(team_id)
  or (is_active and not is_blocked_with_team(team_id))
);

create policy posts_insert on posts for insert to authenticated
with check (is_team_member(team_id) and is_account_active());

create policy posts_update on posts for update to authenticated
using (is_team_owner(team_id) or is_admin());

create policy posts_delete on posts for delete to authenticated
using (is_team_owner(team_id) or is_admin());

-- ---------- matches ----------
create policy matches_select on matches for select to authenticated
using (is_team_member(from_team_id) or is_team_member(to_team_id) or is_admin());

-- 차단 관계인 팀에는 매칭 신청 자체가 불가
create policy matches_insert on matches for insert to authenticated
with check (
  is_team_owner(from_team_id)
  and is_account_active()
  and not is_blocked_with_team(to_team_id)
);

-- 받는 쪽만 수락/거절, 보낸 쪽은 취소
create policy matches_update on matches for update to authenticated
using (is_team_owner(to_team_id) or is_team_owner(from_team_id) or is_admin());

-- ---------- chat_rooms ----------
create policy chat_rooms_select on chat_rooms for select to authenticated
using (is_room_participant(id) or is_admin());

create policy chat_rooms_update on chat_rooms for update to authenticated
using (is_room_participant(id) or is_admin());

-- ---------- messages ----------
create policy messages_select on messages for select to authenticated
using ((is_room_participant(room_id) and deleted_at is null) or is_admin());

create policy messages_insert on messages for insert to authenticated
with check (
  sender_id = auth.uid()
  and is_room_participant(room_id)
  and is_room_open(room_id)
  and is_account_active()
);

-- 본인 메시지 삭제 or 관리자 삭제
create policy messages_update on messages for update to authenticated
using (sender_id = auth.uid() or is_admin());

-- ---------- blocks ----------
create policy blocks_select on blocks for select to authenticated
using (blocker_id = auth.uid() or is_admin());

create policy blocks_insert on blocks for insert to authenticated
with check (blocker_id = auth.uid());

create policy blocks_delete on blocks for delete to authenticated
using (blocker_id = auth.uid());

-- ---------- reports ----------
-- 신고자는 본인 신고만 조회 가능. 피신고자는 볼 수 없음.
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
-- 금칙어 검사는 Edge Function(service_role)이 수행하므로 클라이언트 노출 불필요


-- ============================================================
-- 11. 트리거
-- ============================================================

-- updated_at 자동 갱신
create or replace function touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end; $$;

create trigger profiles_touch before update on profiles
for each row execute function touch_updated_at();


-- 팀 생성 시 owner를 team_members에 자동 등록
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


-- 매칭 수락 시 채팅방 자동 생성
create or replace function create_room_on_match()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  if new.status = 'accepted' and old.status = 'pending' then
    insert into chat_rooms (match_id) values (new.id)
    on conflict (match_id) do nothing;
    new.responded_at = now();
  elsif new.status in ('rejected', 'cancelled') and old.status = 'pending' then
    new.responded_at = now();
  end if;
  return new;
end; $$;

create trigger matches_create_room before update on matches
for each row execute function create_room_on_match();


-- 차단 시 해당 상대와의 채팅방 강제 종료 (체크리스트 1번 요건)
create or replace function close_rooms_on_block()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  update chat_rooms r
  set closed_at = now(), close_reason = 'blocked'
  from matches m
  where r.match_id = m.id
    and r.closed_at is null
    and exists (
      select 1 from team_members a, team_members b
      where a.team_id in (m.from_team_id, m.to_team_id)
        and b.team_id in (m.from_team_id, m.to_team_id)
        and a.user_id = new.blocker_id
        and b.user_id = new.blocked_id
    );
  return new;
end; $$;

create trigger blocks_close_rooms after insert on blocks
for each row execute function close_rooms_on_block();


-- 신고가 '확정 처리'될 때만 누적 카운트 증가 → 3회 경고, 5회 정지
-- (raw 신고 수로 세면 조직적 허위신고에 취약해서 관리자 확정 건만 카운트)
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
      update profiles
      set status = 'warned'
      where id = new.target_user_id;
    end if;

    new.resolved_at = now();
  end if;
  return new;
end; $$;

create trigger reports_apply_strike before update on reports
for each row execute function apply_strike_on_report();


-- ============================================================
-- 12. 인덱스
-- ============================================================

create index idx_team_members_user   on team_members(user_id);
create index idx_posts_active        on posts(created_at desc) where is_active;
create index idx_posts_team          on posts(team_id);
create index idx_matches_to_team     on matches(to_team_id, status);
create index idx_matches_from_team   on matches(from_team_id, status);
create index idx_messages_room       on messages(room_id, created_at desc);
create index idx_blocks_blocked      on blocks(blocked_id);
create index idx_reports_pending     on reports(created_at desc) where status = 'pending';
create index idx_profiles_status     on profiles(status) where deleted_at is null;


-- ============================================================
-- 13. Realtime 활성화 (채팅용)
-- ============================================================

alter publication supabase_realtime add table messages;
alter publication supabase_realtime add table matches;
