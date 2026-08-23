-- ============================================================
-- 마이그레이션 012 — 알림
--
-- 배경
--   app/temp/temp_notification.tsx 는 하드코딩된 알림 세 줄이었다.
--   "매칭 신청이 왔어요", "매칭이 성사됐어요" 같은 문장은 이미 서버가
--   아는 사실인데(matches 한 줄이 바뀌는 순간이 곧 그 사건이다), 저장할
--   곳이 없어서 화면에만 흉내로 남아 있었다.
--
--   화면에서 만들면 안 되는 이유는 분명하다. 알림을 받아야 하는 사람은
--   대개 그 순간 앱을 보고 있지 않다. 신청을 받은 팀장은 다른 화면에 있고,
--   자동 거절된 팀은 아예 앱을 꺼 두었다. 사건이 일어나는 곳(트리거)에서
--   같은 트랜잭션으로 남겨야 빠짐없이 쌓인다.
--
-- 무엇을 만드나
--   notifications 테이블 하나 + 사건마다 붙는 트리거 다섯 개.
--   알림 문구는 전부 서버가 만든다 — 두 팀이 같은 사건을 서로 반대편에서
--   보므로("우리가 신청했다" vs "신청이 왔다"), 받는 사람 기준으로 뒤집는
--   일을 클라이언트 두 곳에서 따로 하면 반드시 어긋난다.
--
--   반대로 '눌렀을 때 어디로 가는가'는 서버가 정하지 않는다. 앱 라우트는
--   앱이 바뀔 때마다 바뀌므로, 대상 id(team_id / match_id / room_id)만
--   남기고 경로는 프론트 utils/notifications.ts 가 만든다.
--
-- 알림을 만들지 않는 것
--   채팅 메시지. 방 하나에 수십 줄이 오가는데 줄마다 알림을 쌓으면
--   알림 센터가 채팅 로그가 된다. 채팅은 Realtime 구독(messages)이
--   이미 실시간으로 처리하고 있다.
--
-- 푸시 알림(APNs/FCM)은 아직 없다
--   이 마이그레이션은 '앱 안의 알림 센터'까지다. 기기로 밀어 넣는 푸시는
--   expo-notifications + 기기 토큰 테이블 + Edge Function 이 더 필요하다.
--   그때도 이 테이블이 그대로 출처가 된다 — insert 를 듣고 보내면 된다.
--
-- 실행: Supabase Dashboard → SQL Editor 에 통째로 붙여넣고 Run
--       (전제: dku_meeting_schema_v2.sql + 마이그레이션 002~011)
--       여러 번 돌려도 안전하다.
-- ============================================================


-- ------------------------------------------------------------
-- 1. 알림 종류
--
--    create type 에는 if not exists 가 없다. 두 번 돌려도 42710 으로
--    멈추지 않게 감싼다.
--
--    ⚠️ 값을 새로 추가할 때는 alter type ... add value 로 뒤에 붙일 것.
--       프론트 utils/notifications.ts 가 모르는 값이 오면 기본 아이콘으로
--       떨어지므로, 앱을 먼저 배포하지 않아도 화면이 깨지지는 않는다.
-- ------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'notification_kind') then
    create type notification_kind as enum (
      'MATCH_REQUEST',    -- 우리 팀에 매칭 신청이 들어왔다
      'MATCH_ACCEPTED',   -- 매칭 성사 (양쪽 모두)
      'MATCH_REJECTED',   -- 내가 보낸 신청이 거절되었다 (자동 거절 포함)
      'MATCH_CANCELED',   -- 받아 둔 신청을 보낸 쪽이 취소했다
      'TEAM_JOINED',      -- 초대 코드로 새 팀원이 들어왔다
      'TEAM_READY',       -- 정원이 다 찼다 (팀장에게: 이제 공개할 수 있다)
      'PLAN_SET',         -- 약속이 정해졌거나 취소되었다
      'NOTICE'            -- 운영 공지
    );
  end if;
end $$;


-- ------------------------------------------------------------
-- 2. 테이블
--
--    title / body 를 그대로 저장한다(정규화하지 않는다).
--    알림은 '그때 그 순간의 기록'이라 나중에 팀 이름이 바뀌어도 예전 알림
--    문구는 그대로여야 한다. 지금 값을 조인해서 다시 만들면 지난 알림이
--    소리 없이 다른 말을 하게 된다.
--
--    대상 id 세 개는 전부 nullable 이다. 어떤 알림에 무엇이 붙는지는
--    아래 트리거가 정한다. cascade 로 지우는 이유는, 대상이 사라지면
--    눌러도 갈 곳이 없어 알림만 남겨 둘 이유가 없기 때문이다.
-- ------------------------------------------------------------
create table if not exists notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles(id)   on delete cascade,
  kind       notification_kind not null,
  title      text not null check (length(title) between 1 and 100),
  body       text not null check (length(body)  between 1 and 300),

  -- 눌렀을 때 열 대상. 종류에 따라 하나 이상이 채워진다.
  team_id    uuid references teams(id)       on delete cascade,
  match_id   uuid references matches(id)     on delete cascade,
  room_id    uuid references chat_rooms(id)  on delete cascade,

  -- 읽은 시각. null 이면 안 읽음 (뱃지가 세는 값이다)
  read_at    timestamptz,
  created_at timestamptz not null default now()
);

comment on table notifications is
  '알림 센터. 클라이언트는 읽기만 하고, 쓰기는 전부 트리거/RPC 가 한다 (마이그레이션 012)';

-- 알림 목록: 내 것을 최신순으로. 화면이 하는 유일한 조회 모양이다.
create index if not exists idx_notifications_user
  on notifications(user_id, created_at desc);

-- 안 읽은 개수: 뱃지가 앱을 켤 때마다 세므로 부분 인덱스로 좁혀 둔다.
create index if not exists idx_notifications_unread
  on notifications(user_id) where read_at is null;


-- ------------------------------------------------------------
-- 3. RLS
--
--    읽기만 연다. insert 는 트리거(security definer = 테이블 소유자 권한)가
--    하므로 정책을 통과할 필요가 없고, update 는 RPC 로만 연다.
--
--    왜 update 를 직접 열지 않는가
--      RLS 에는 컬럼 단위가 없다. `user_id = auth.uid()` 로 열면 read_at
--      뿐 아니라 title/body/kind 까지 바꿀 수 있는 문이 함께 열린다.
--      제 알림을 스스로 위조하는 것뿐이라 피해자는 자기 자신이지만,
--      "서버가 만든 문구"라는 전제가 깨지면 나중에 푸시를 붙일 때
--      이 테이블을 그대로 믿을 수 없게 된다. 마이그레이션 011 이
--      messages 에 한 것과 같은 이유다.
-- ------------------------------------------------------------
alter table notifications enable row level security;

drop policy if exists notifications_select         on notifications;
drop policy if exists notifications_insert_denied  on notifications;
drop policy if exists notifications_update_denied  on notifications;

create policy notifications_select on notifications for select to authenticated
using (user_id = auth.uid() or is_admin());

create policy notifications_insert_denied on notifications for insert to authenticated
with check (false);

create policy notifications_update_denied on notifications for update to authenticated
using (false);

comment on policy notifications_insert_denied on notifications is
  '알림은 트리거만 만든다 (마이그레이션 012)';
comment on policy notifications_update_denied on notifications is
  '읽음 표시는 mark_notification_read / mark_all_notifications_read 로만 (마이그레이션 012)';

grant select on notifications to authenticated;


-- ------------------------------------------------------------
-- 4. 알림을 남기는 두 가지 방법
--
--    notify_user  — 한 사람에게 (팀장에게만 가는 알림)
--    notify_team  — 팀원 전체에게 (팀에 일어난 일)
--
--    두 함수 모두 조용히 실패한다. 알림을 못 남겼다고 매칭 수락이나 팀
--    합류가 통째로 롤백되면 본말이 뒤집힌다 — 알림은 곁다리다.
--    (그래서 탈퇴한 계정은 raise 없이 그냥 건너뛴다)
-- ------------------------------------------------------------
create or replace function notify_user(
  p_user_id  uuid,
  p_kind     notification_kind,
  p_title    text,
  p_body     text,
  p_team_id  uuid default null,
  p_match_id uuid default null,
  p_room_id  uuid default null
)
returns void language plpgsql security definer
set search_path = public as $$
begin
  if p_user_id is null then
    return;
  end if;

  -- 탈퇴한 계정에는 쌓지 않는다. 정지(suspended)는 남긴다 — 정지가 풀리면
  -- 그 사이에 무슨 일이 있었는지 봐야 한다.
  if not exists (
    select 1 from profiles where id = p_user_id and deleted_at is null
  ) then
    return;
  end if;

  insert into notifications (user_id, kind, title, body, team_id, match_id, room_id)
  values (p_user_id, p_kind, p_title, p_body, p_team_id, p_match_id, p_room_id);
end; $$;

/**
 * 팀원 전체에게.
 *
 * p_except_user 는 '사건을 일으킨 사람'을 빼는 데 쓴다. 약속을 방금 저장한
 * 사람에게 "약속이 정해졌어요"를 보내면 자기가 누른 버튼을 알림으로
 * 되돌려받는 꼴이 된다.
 */
create or replace function notify_team(
  p_team_id      uuid,
  p_kind         notification_kind,
  p_title        text,
  p_body         text,
  p_match_id     uuid default null,
  p_room_id      uuid default null,
  p_except_user  uuid default null
)
returns void language plpgsql security definer
set search_path = public as $$
begin
  insert into notifications (user_id, kind, title, body, team_id, match_id, room_id)
  select tm.user_id, p_kind, p_title, p_body, p_team_id, p_match_id, p_room_id
  from team_members tm
  join profiles p on p.id = tm.user_id and p.deleted_at is null
  where tm.team_id = p_team_id
    and (p_except_user is null or tm.user_id <> p_except_user);
end; $$;

-- 트리거 전용이다. 앱이 부를 수 있으면 아무 문구나 남의 알림함에 넣을 수 있다.
revoke all on function notify_user(uuid, notification_kind, text, text, uuid, uuid, uuid) from public;
revoke all on function notify_user(uuid, notification_kind, text, text, uuid, uuid, uuid) from anon;
revoke all on function notify_user(uuid, notification_kind, text, text, uuid, uuid, uuid) from authenticated;

revoke all on function notify_team(uuid, notification_kind, text, text, uuid, uuid, uuid) from public;
revoke all on function notify_team(uuid, notification_kind, text, text, uuid, uuid, uuid) from anon;
revoke all on function notify_team(uuid, notification_kind, text, text, uuid, uuid, uuid) from authenticated;


-- ------------------------------------------------------------
-- 5. 매칭 신청이 들어왔다 (after insert on matches)
--
--    받는 팀 '전원'에게 보낸다. 수락은 팀장만 할 수 있지만, 누가 신청했는지는
--    팀원도 같이 보고 정하는 일이다(match/party/[id].tsx 는 팀원도 열 수 있다).
--
--    보낸 팀에는 알리지 않는다 — 방금 자기가 누른 버튼이다.
-- ------------------------------------------------------------
create or replace function notify_on_match_request()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_from teams%rowtype;
  v_to   teams%rowtype;
begin
  select * into v_from from teams where id = new.from_team_id;
  select * into v_to   from teams where id = new.to_team_id;

  perform notify_team(
    new.to_team_id,
    'MATCH_REQUEST',
    '매칭 신청이 왔어요 💌',
    format('%s 팀이 「%s」 에 매칭을 신청했어요.', v_from.dept, v_to.title),
    p_match_id => new.id
  );

  return null;   -- after 트리거의 반환값은 쓰이지 않는다
end; $$;

drop trigger if exists matches_notify_request on matches;
create trigger matches_notify_request
after insert on matches
for each row execute function notify_on_match_request();


-- ------------------------------------------------------------
-- 6. 신청에 답이 왔다 / 약속이 정해졌다 (after update on matches)
--
--    matches 한 줄의 update 는 세 가지 사건을 나른다. 어느 쪽인지는
--    무엇이 바뀌었는지로 가른다.
--
--    ⚠️ 자동 거절(cascade)을 따로 다루는 이유
--       한 팀이 수락하면 마이그레이션 009 의 on_match_accepted 가 두 팀에
--       걸린 나머지 WAITING 을 전부 REJECTED 로 바꾼다. 그 줄들에도 이
--       트리거가 걸리는데, 그대로 두면 방금 매칭에 성공한 팀원들이
--       "매칭 성사" 와 "신청 거절" 을 한꺼번에 받는다.
--
--       cascade 로 거절된 줄에서 두 팀 중 하나는 반드시 방금 MATCHED 가 된
--       팀이다(그래서 이 줄이 정리되는 것이다). 그쪽은 이미 성사 알림을
--       받았으므로 건너뛰고, 남은 팀에만 "상대가 다른 팀과 매칭됐다"를
--       알린다. 009 의 app.match_cascade 표식을 그대로 읽어 쓴다.
--
--    ⚠️ 거절과 취소를 가르는 기준
--       서버에서는 같은 한 줄(status = 'REJECTED')이다. 누가 눌렀는지로만
--       갈린다 — 보낸 팀 사람이면 '취소', 아니면 받은 팀 팀장의 '거절'.
-- ------------------------------------------------------------
create or replace function notify_on_match_update()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_from  teams%rowtype;
  v_to    teams%rowtype;
  v_room  uuid;
  v_actor uuid := auth.uid();
  v_body  text;
begin
  select * into v_from from teams where id = new.from_team_id;
  select * into v_to   from teams where id = new.to_team_id;

  -- ── 상태가 바뀐 경우 ──────────────────────────────────
  if new.status is distinct from old.status then

    if new.status = 'ACCEPTED' then
      -- 방은 on_match_accepted 가 이미 만들어 두었다(before update).
      select id into v_room from chat_rooms where match_id = new.id;

      perform notify_team(
        new.from_team_id, 'MATCH_ACCEPTED', '매칭이 성사됐어요 🎉',
        format('%s 팀과 매칭됐어요. 채팅을 시작해보세요!', v_to.dept),
        p_match_id => new.id, p_room_id => v_room
      );
      perform notify_team(
        new.to_team_id, 'MATCH_ACCEPTED', '매칭이 성사됐어요 🎉',
        format('%s 팀과 매칭됐어요. 채팅을 시작해보세요!', v_from.dept),
        p_match_id => new.id, p_room_id => v_room
      );

    elsif new.status = 'REJECTED' then

      if coalesce(current_setting('app.match_cascade', true), 'off') = 'on' then
        -- 자동 거절. 방금 매칭된 쪽(MATCHED)은 건너뛴다.
        if v_from.status <> 'MATCHED' then
          perform notify_team(
            new.from_team_id, 'MATCH_REJECTED', '신청이 종료됐어요',
            format('%s 팀이 다른 팀과 매칭됐어요. 아쉽지만 다른 팀을 찾아볼까요?', v_to.dept),
            p_match_id => new.id
          );
        end if;
        if v_to.status <> 'MATCHED' then
          perform notify_team(
            new.to_team_id, 'MATCH_REJECTED', '신청이 종료됐어요',
            format('%s 팀이 다른 팀과 매칭됐어요. 받아 둔 신청이 정리됐어요.', v_from.dept),
            p_match_id => new.id
          );
        end if;

      elsif v_actor is not null and exists (
        select 1 from team_members
        where team_id = new.from_team_id and user_id = v_actor
      ) then
        -- 보낸 팀이 스스로 취소했다 → 기다리던 받은 팀에 알린다.
        -- (MATCHED 확인은 여기서는 늘 참이다 — 매칭된 팀에는 대기중 신청이
        --  남아 있을 수 없다. 위 cascade 판정이 어긋나도 "성사"와 "종료"가
        --  함께 날아가지는 않게 규칙을 한 번 더 적어 둔다.)
        if v_to.status <> 'MATCHED' then
          perform notify_team(
            new.to_team_id, 'MATCH_CANCELED', '신청이 취소됐어요',
            format('%s 팀이 매칭 신청을 취소했어요.', v_from.dept),
            p_match_id => new.id, p_except_user => v_actor
          );
        end if;

      else
        -- 받은 팀 팀장이 거절했다 → 기다리던 보낸 팀에 알린다
        if v_from.status <> 'MATCHED' then
          perform notify_team(
            new.from_team_id, 'MATCH_REJECTED', '신청이 거절됐어요',
            format('%s 팀이 신청을 거절했어요. 다른 팀에 다시 신청해보세요.', v_to.dept),
            p_match_id => new.id
          );
        end if;
      end if;
    end if;

    return null;
  end if;

  -- ── 약속이 바뀐 경우 ──────────────────────────────────
  --    set_match_plan RPC 는 팀원 누구나 부를 수 있다. 누른 사람만 빼고
  --    양 팀 전원에게 알린다.
  if new.plan_date  is distinct from old.plan_date
     or new.plan_time  is distinct from old.plan_time
     or new.plan_place is distinct from old.plan_place then

    select id into v_room from chat_rooms where match_id = new.id;

    if new.plan_date is null then
      perform notify_team(new.from_team_id, 'PLAN_SET', '약속이 취소됐어요',
        '정해뒀던 약속이 취소됐어요. 채팅방에서 다시 정해보세요.',
        p_match_id => new.id, p_room_id => v_room, p_except_user => v_actor);
      perform notify_team(new.to_team_id, 'PLAN_SET', '약속이 취소됐어요',
        '정해뒀던 약속이 취소됐어요. 채팅방에서 다시 정해보세요.',
        p_match_id => new.id, p_room_id => v_room, p_except_user => v_actor);
    else
      -- "8월 23일 19:00 · 죽전역 근처"
      -- time 은 to_char 가 직접 받지 않는다. "19:00:00" 의 앞 다섯 글자면 충분하다.
      v_body := format('%s %s%s 에 만나요.',
        to_char(new.plan_date, 'FMMM월 FMDD일'),
        substr(new.plan_time::text, 1, 5),
        coalesce(' · ' || nullif(trim(new.plan_place), ''), '')
      );

      perform notify_team(new.from_team_id, 'PLAN_SET', '약속이 정해졌어요 📅', v_body,
        p_match_id => new.id, p_room_id => v_room, p_except_user => v_actor);
      perform notify_team(new.to_team_id, 'PLAN_SET', '약속이 정해졌어요 📅', v_body,
        p_match_id => new.id, p_room_id => v_room, p_except_user => v_actor);
    end if;
  end if;

  return null;
end; $$;

drop trigger if exists matches_notify_update on matches;
create trigger matches_notify_update
after update on matches
for each row execute function notify_on_match_update();


-- ------------------------------------------------------------
-- 7. 새 팀원이 들어왔다 (after insert on team_members)
--
--    팀을 막 만든 순간에도 이 트리거가 돈다(teams_add_owner 가 팀장을
--    넣는다). 그때 팀에는 팀장 혼자뿐이고 그 팀장은 p_except_user 로
--    빠지므로 알림은 한 줄도 생기지 않는다.
--
--    ⚠️ filled_count 를 teams 에서 읽지 않고 직접 센다.
--       같은 시점에 도는 team_members_sync_fill 도 after 트리거라서,
--       둘의 실행 순서는 트리거 '이름' 순이다(n < s → 이쪽이 먼저).
--       teams.filled_count 는 아직 한 명 적은 값이다.
-- ------------------------------------------------------------
create or replace function notify_on_team_join()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_team  teams%rowtype;
  v_name  text;
  v_count int;
begin
  select * into v_team from teams where id = new.team_id;
  if not found then
    return null;
  end if;

  select coalesce(nullif(trim(p.nickname), ''), p.name) into v_name
  from profiles p where p.id = new.user_id;

  select count(*) into v_count from team_members where team_id = new.team_id;

  perform notify_team(
    new.team_id,
    'TEAM_JOINED',
    '새 팀원이 들어왔어요',
    format('%s 님이 「%s」 에 합류했어요. (%s/%s)',
           coalesce(v_name, '밋단 회원'), v_team.title, v_count, v_team.capacity),
    p_except_user => new.user_id
  );

  return null;
end; $$;

drop trigger if exists team_members_notify_join on team_members;
create trigger team_members_notify_join
after insert on team_members
for each row execute function notify_on_team_join();


-- ------------------------------------------------------------
-- 8. 팀원이 다 모였다 (after update on teams)
--
--    정원이 차면 sync_team_fill 이 RECRUITING → READY 로 올린다. 그런데
--    READY 는 '비공개' 상태라 여기서 멈추면 아무 일도 일어나지 않는다.
--    게시판에 올리는 건 팀장이 한 번 더 눌러야 하므로, 그 사실을 팀장에게만
--    알린다.
--
--    ⚠️ old.status = 'RECRUITING' 을 함께 본다.
--       팀장이 공개를 내리는 경우(ACTIVE → READY)도 같은 new.status 라서,
--       이걸 빼면 비공개로 돌릴 때마다 "팀원이 다 모였어요"가 날아온다.
-- ------------------------------------------------------------
create or replace function notify_on_team_ready()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  if old.status = 'RECRUITING' and new.status = 'READY' then
    perform notify_user(
      new.owner_id,
      'TEAM_READY',
      '팀원이 다 모였어요',
      -- 제목 뒤에 조사를 붙이지 않는다. 받침 유무에 따라 을/를 이/가 가
      -- 달라지는데 팀 제목은 사용자가 자유롭게 쓰는 값이라 맞출 수가 없다.
      format('「%s」 — 게시판에 공개하면 매칭 신청을 받을 수 있어요.', new.title),
      p_team_id => new.id
    );
  end if;

  return null;
end; $$;

drop trigger if exists teams_notify_ready on teams;
create trigger teams_notify_ready
after update on teams
for each row execute function notify_on_team_ready();


-- ------------------------------------------------------------
-- 9. 읽음 표시 / 공지 — 앱이 부르는 RPC
-- ------------------------------------------------------------

/** 알림 하나를 읽음으로. 이미 읽은 줄은 시각을 덮어쓰지 않는다. */
create or replace function mark_notification_read(p_id uuid)
returns void language sql security definer
set search_path = public as $$
  update notifications
  set read_at = now()
  where id = p_id and user_id = auth.uid() and read_at is null;
$$;

/** 안 읽은 알림 전부를 읽음으로. 바뀐 줄 수를 돌려준다. */
create or replace function mark_all_notifications_read()
returns int language plpgsql security definer
set search_path = public as $$
declare
  v_count int;
begin
  update notifications
  set read_at = now()
  where user_id = auth.uid() and read_at is null;

  get diagnostics v_count = row_count;
  return v_count;
end; $$;

/**
 * 운영 공지. 살아 있는 계정 전원에게 한 줄씩 넣는다.
 * 사람 수만큼 행이 생기므로 짧은 공지에만 쓸 것.
 *
 * ⚠️ SQL Editor 에서 이 함수를 그냥 부르면 '운영자만 공지를 보낼 수
 *    있습니다' 로 막힌다. is_admin() 이 보는 것은 auth.uid() 인데,
 *    SQL Editor 는 postgres 로 붙고 JWT 가 없어서 그 값이 null 이다.
 *    admins 에 등록했든 아니든 결과는 같다.
 *
 *    이 함수는 '로그인한 운영자가 앱/API 를 통해' 부르는 길이다.
 *    SQL Editor 에서 공지를 보내려면 둘 중 하나를 쓴다.
 *
 *    (a) 그냥 직접 넣는다. postgres 는 RLS 를 지나가므로 정책에 막히지
 *        않고, 013 의 푸시 트리거도 똑같이 돈다.
 *
 *          insert into notifications (user_id, kind, title, body)
 *          select id, 'NOTICE', '제목', '내용'
 *          from profiles where deleted_at is null;
 *
 *    (b) 운영자인 척하고 이 함수를 부른다. 권한 검사까지 함께 시험하고
 *        싶을 때만. set_config 는 트랜잭션 한정이라 begin/commit 으로
 *        묶어야 두 문장이 같은 트랜잭션에 든다.
 *
 *          begin;
 *          select set_config('request.jwt.claims',
 *            json_build_object(
 *              'sub',  (select id from profiles where login_id = '내아이디'),
 *              'role', 'authenticated')::text, true);
 *          select broadcast_notice('제목', '내용');
 *          commit;
 */
create or replace function broadcast_notice(p_title text, p_body text)
returns int language plpgsql security definer
set search_path = public as $$
declare
  v_count int;
begin
  if not is_admin() then
    raise exception '운영자만 공지를 보낼 수 있습니다' using errcode = 'insufficient_privilege';
  end if;

  insert into notifications (user_id, kind, title, body)
  select id, 'NOTICE', p_title, p_body
  from profiles
  where deleted_at is null and status <> 'deleted';

  get diagnostics v_count = row_count;
  return v_count;
end; $$;

revoke all on function mark_notification_read(uuid)       from public;
revoke all on function mark_all_notifications_read()      from public;
revoke all on function broadcast_notice(text, text)       from public;

grant execute on function mark_notification_read(uuid)    to authenticated;
grant execute on function mark_all_notifications_read()   to authenticated;
grant execute on function broadcast_notice(text, text)    to authenticated;  -- 함수 안에서 is_admin() 이 다시 막는다


-- ------------------------------------------------------------
-- 10. Realtime
--
--     알림 뱃지가 화면을 새로 열지 않고도 켜지게 한다. 구독에도 RLS 가
--     걸리므로 남의 알림은 애초에 도착하지 않는다.
--
--     이미 들어 있는 테이블을 또 추가하면 오류가 나므로 확인하고 붙인다.
-- ------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'notifications'
  ) then
    alter publication supabase_realtime add table notifications;
  end if;
end $$;


-- ------------------------------------------------------------
-- 11. 확인
--
--     앱에서 신청 → 수락까지 한 번 돌린 뒤 아래를 실행해 본다.
-- ------------------------------------------------------------
-- -- (1) 알림이 쌓이고 있나 (최근 20줄)
-- select n.created_at, p.login_id, n.kind, n.title, n.body, n.read_at is null as 안읽음
-- from notifications n
-- join profiles p on p.id = n.user_id
-- order by n.created_at desc
-- limit 20;
--
-- -- (2) 트리거 다섯 개가 제자리에 있나
-- select c.relname as 테이블, t.tgname as 트리거, p.proname as 함수
-- from pg_trigger t
-- join pg_class c on c.oid = t.tgrelid
-- join pg_proc  p on p.oid = t.tgfoid
-- where not t.tgisinternal and p.proname like 'notify_on_%'
-- order by c.relname, t.tgname;
--
-- -- (3) 직접 쓰기가 막히는가 (둘 다 0행이어야 정상)
-- --     set local role authenticated;
-- --     select set_config('request.jwt.claims', '{"sub":"<내 uuid>","role":"authenticated"}', true);
-- --     insert into notifications (user_id, kind, title, body)
-- --     values ('<내 uuid>', 'NOTICE', '가짜', '직접 넣기');   -- 42501 이어야 한다
-- --     update notifications set title = '바꿔치기' where user_id = '<내 uuid>';  -- 0행
--
-- -- (4) 오래된 알림 정리 — 지금은 자동으로 지우지 않는다.
-- --     쌓이는 속도를 보고 필요해지면 pg_cron 으로 아래를 하루 한 번 돌린다.
-- -- delete from notifications
-- -- where read_at is not null and created_at < now() - interval '60 days';
