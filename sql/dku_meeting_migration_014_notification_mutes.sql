-- ============================================================
-- 마이그레이션 014 — 알림 설정 (종류별 끄기)
--
-- 012 는 사건이 생기면 무조건 알림을 남긴다. 팀원이 여섯 명인 방에서
-- 약속을 두어 번 고치면 그것만으로 알림함이 채워지고, 그러면 정작 중요한
-- "매칭 신청이 왔어요" 가 묻힌다. 끌 수 있어야 한다.
--
-- 어떻게 저장하나 — '끈 것'만 남긴다
--   기본값은 전부 켜짐이다. 그래서 notification_mutes 에는 끈 종류만 한 줄씩
--   들어간다. 반대로 '켠 것'을 저장하면
--     · 기존 가입자 전원에게 기본값 행을 만들어 주는 백필이 필요하고
--     · 종류를 새로 추가할 때마다 또 백필해야 하고
--     · 행이 없는 사람을 '전부 끔'으로 잘못 읽을 여지가 생긴다.
--   끈 것만 남기면 셋 다 없다. 행이 없으면 그냥 다 받는 사람이다.
--
-- 어디서 막나 — 만드는 자리에서
--   012 의 notify_user / notify_team 한 곳만 고친다. 알림이 만들어지는
--   길이 그 둘뿐이라(트리거 다섯 개가 전부 이 둘을 부른다), 여기서 걸러내면
--   새 트리거를 나중에 붙여도 설정이 저절로 지켜진다.
--
-- ⚠️ 끄면 알림함에도 안 쌓인다. 푸시만 막는 게 아니다.
--    두 단계(앱 안 / 기기 푸시)로 나누면 설정이 8개에서 16개가 되는데,
--    그만큼의 선택지가 필요할 만큼 알림 종류가 많지 않다. 대신 사건 자체는
--    [활동] 탭과 [내 팀] 탭에 그대로 남으므로 놓치는 정보는 없다.
--    (나중에 푸시를 켜면 이 설정이 푸시까지 함께 다스린다 — 알림이 아예
--     안 만들어지니 013 의 발송 트리거도 돌지 않는다)
--
-- 무엇을 끌 수 있게 할지는 앱이 정한다
--   이 테이블은 종류 여덟 가지를 다 받는다. 화면(utils/notifications.ts)이
--   그중 넷을 묶어서 보여주고 공지는 빼 둔다. 정책이 바뀌어도 서버는
--   그대로다.
--
-- 실행: Supabase Dashboard → SQL Editor 에 통째로 붙여넣고 Run
--       (전제: 마이그레이션 012)
--       여러 번 돌려도 안전하다.
-- ============================================================


-- ------------------------------------------------------------
-- 1. 끈 알림 종류
-- ------------------------------------------------------------
create table if not exists notification_mutes (
  user_id    uuid not null references profiles(id) on delete cascade,
  kind       notification_kind not null,
  created_at timestamptz not null default now(),

  primary key (user_id, kind)
);

comment on table notification_mutes is
  '사용자가 끈 알림 종류. 행이 없으면 받는다는 뜻 (마이그레이션 014)';

alter table notification_mutes enable row level security;

drop policy if exists notification_mutes_select        on notification_mutes;
drop policy if exists notification_mutes_insert_denied on notification_mutes;
drop policy if exists notification_mutes_update_denied on notification_mutes;
drop policy if exists notification_mutes_delete_denied on notification_mutes;

-- 읽기는 연다. 설정 화면이 스위치의 현재 상태를 그리려면 필요하다.
create policy notification_mutes_select on notification_mutes for select to authenticated
using (user_id = auth.uid() or is_admin());

-- 쓰기는 RPC 로만. 직접 열면 남의 uuid 로 행을 넣어 그 사람 알림을 끌 수 있다.
create policy notification_mutes_insert_denied on notification_mutes for insert to authenticated
with check (false);

create policy notification_mutes_update_denied on notification_mutes for update to authenticated
using (false);

create policy notification_mutes_delete_denied on notification_mutes for delete to authenticated
using (false);

grant select on notification_mutes to authenticated;


-- ------------------------------------------------------------
-- 2. 이 사람이 이 종류를 받는가
--
--    stable 이라 한 문장 안에서 여러 번 불려도 계획에 따라 한 번만 돌 수 있다.
--    notify_team 이 팀원 수만큼 부르는 자리라 그 편이 낫다.
-- ------------------------------------------------------------
create or replace function notification_enabled(
  p_user_id uuid,
  p_kind    notification_kind
)
returns boolean language sql security definer stable
set search_path = public as $$
  select not exists (
    select 1 from notification_mutes
    where user_id = p_user_id and kind = p_kind
  );
$$;


-- ------------------------------------------------------------
-- 3. 012 의 두 함수를 다시 만든다
--
--    바뀐 것은 각각 ⭐ 한 줄뿐이다. 나머지는 012 와 같다 —
--    함수는 통째로만 바꿀 수 있어서 전부 다시 적는다.
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

  -- ⭐ 014: 이 종류를 꺼 둔 사람이면 만들지 않는다
  if not notification_enabled(p_user_id, p_kind) then
    return;
  end if;

  insert into notifications (user_id, kind, title, body, team_id, match_id, room_id)
  values (p_user_id, p_kind, p_title, p_body, p_team_id, p_match_id, p_room_id);
end; $$;

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
    and (p_except_user is null or tm.user_id <> p_except_user)
    -- ⭐ 014: 이 종류를 꺼 둔 팀원은 건너뛴다
    and notification_enabled(tm.user_id, p_kind);
end; $$;


-- ------------------------------------------------------------
-- 4. 설정 저장 — 앱이 부르는 RPC
--
--    한 번에 여러 종류를 받는다. 화면의 스위치 하나가 종류 여럿을 묶고
--    있어서(예: '매칭 결과' = 성사 + 거절 + 취소), 하나씩 부르면 스위치
--    한 번에 왕복이 세 번 생긴다.
-- ------------------------------------------------------------
create or replace function set_notification_mutes(
  p_kinds notification_kind[],
  p_muted boolean
)
returns void language plpgsql security definer
set search_path = public as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception '로그인이 필요합니다' using errcode = 'insufficient_privilege';
  end if;

  if p_kinds is null or array_length(p_kinds, 1) is null then
    return;
  end if;

  if p_muted then
    insert into notification_mutes (user_id, kind)
    select v_user, k from unnest(p_kinds) as k
    on conflict (user_id, kind) do nothing;
  else
    delete from notification_mutes
    where user_id = v_user and kind = any(p_kinds);
  end if;
end; $$;

revoke all on function set_notification_mutes(notification_kind[], boolean) from public;
grant execute on function set_notification_mutes(notification_kind[], boolean) to authenticated;

-- notification_enabled 는 트리거가 쓰는 내부 함수다. 앱이 부를 일이 없다.
revoke all on function notification_enabled(uuid, notification_kind) from public;
revoke all on function notification_enabled(uuid, notification_kind) from anon;
revoke all on function notification_enabled(uuid, notification_kind) from authenticated;


-- ------------------------------------------------------------
-- 5. 확인
-- ------------------------------------------------------------
-- -- (1) 누가 무엇을 껐나
-- select p.login_id, m.kind, m.created_at
-- from notification_mutes m join profiles p on p.id = m.user_id
-- order by m.created_at desc;
--
-- -- (2) 설정이 실제로 먹히는가
-- --     끈 종류로 알림을 만들어 보고 0행이 들어가는지 본다.
-- --     ('<내 uuid>' 는 select id from profiles where login_id = '내아이디')
-- -- select set_notification_mutes(array['NOTICE']::notification_kind[], true);
-- --   ↑ 는 auth.uid() 가 필요해 SQL Editor 에서 바로 안 된다. 앱에서 끄거나
-- --     아래처럼 직접 넣는다.
-- -- insert into notification_mutes (user_id, kind) values ('<내 uuid>', 'NOTICE');
-- -- select notify_user('<내 uuid>', 'NOTICE', '시험', '이 줄은 안 들어가야 한다');
-- -- select count(*) from notifications where user_id = '<내 uuid>' and title = '시험';
-- --   → 0 이면 정상. 확인 뒤 정리:
-- -- delete from notification_mutes where user_id = '<내 uuid>' and kind = 'NOTICE';
