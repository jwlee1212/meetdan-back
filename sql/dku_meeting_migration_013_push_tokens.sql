-- ============================================================
-- 마이그레이션 013 — 푸시 알림 (기기 토큰 + 발송 트리거)
--
-- 🅿️ 보류 중 (2026-08-23). 아직 실행하지 않았다.
--
--    코드는 다 있는데 막힌 곳은 코드가 아니다 — 발송 자격증명과 빌드다.
--      · Android : Firebase 프로젝트 + FCM V1 서비스 계정 키
--      · iOS     : Apple Developer 계정 (연 $99) → APNs 키
--      · 공통    : 개발 빌드. Expo Go 는 SDK 53 부터 원격 푸시를 못 받는다.
--    셋 다 정식 출시 준비와 함께 해야 하는 일이라, 그때까지 미뤄 둔다.
--
--    이미 끝난 준비물 하나: eas init (app.json 의 extra.eas.projectId).
--
--    보류 중이어도 앱은 멀쩡하다. 토큰을 못 받으면 lib/push.ts 가 조용히
--    null 을 돌려주고, 등록할 기기가 없으니 이 파일이 없어도 아무 데서도
--    오류가 나지 않는다. 알림 센터(012)는 그것과 무관하게 돌아간다.
--
--    다시 시작할 때: 아래 4번의 준비물 세 가지부터 보면 된다.
--
-- 012 는 '앱 안의 알림 센터'까지였다. 알림은 쌓이지만, 앱을 꺼 둔 사람은
-- 다음에 앱을 열 때까지 아무것도 모른다. 매칭 신청은 상대가 기다리는
-- 일이라 그 시차가 그대로 응답률이 된다.
--
-- 흐름
--   notifications insert
--     → 이 트리거가 Edge Function 을 부른다 (pg_net, 비동기)
--     → send-push 가 그 사람의 기기 토큰을 찾아 Expo Push API 로 보낸다
--
--   012 의 트리거들은 손대지 않는다. 알림을 '만드는' 곳은 그대로 두고,
--   만들어진 알림을 '내보내는' 한 겹만 뒤에 붙인다. 그래서 푸시가 통째로
--   고장 나도 알림 센터는 멀쩡하다.
--
-- ⚠️ 이 마이그레이션만으로는 푸시가 나가지 않는다
--    아래 4번의 준비물 세 가지가 있어야 한다.
--      (1) pg_net 확장
--      (2) Vault 에 project_url / service_role_key
--      (3) send-push Edge Function 배포
--    셋 중 하나라도 없으면 트리거는 조용히 아무 일도 하지 않는다(경고만
--    남긴다). 알림 저장과 매칭 수락은 그대로 성공한다 — 푸시를 못 보낸 것이
--    매칭을 되돌릴 이유는 없기 때문이다.
--
-- 실행: Supabase Dashboard → SQL Editor 에 통째로 붙여넣고 Run
--       (전제: 마이그레이션 012)
--       여러 번 돌려도 안전하다.
-- ============================================================


-- ------------------------------------------------------------
-- 1. 기기 토큰
--
--    기본키가 user_id 가 아니라 token 이다.
--    한 사람이 폰과 태블릿을 함께 쓰면 토큰이 둘이고, 반대로 한 기기를
--    두 사람이 번갈아 쓰면(로그아웃 후 다른 계정 로그인) 같은 토큰의
--    주인이 바뀐다. 토큰을 키로 두면 두 경우가 모두 자연스럽게 풀린다 —
--    후자는 upsert 한 번으로 주인만 갈아끼워진다.
--
--    ⚠️ 토큰은 비밀이 아니지만 개인 식별자다. RLS 로 남의 토큰은 못 본다.
--       (토큰을 알면 그 기기에 알림을 보낼 수 있다. Expo 가 프로젝트
--        자격증명을 함께 보므로 남이 아무렇게나 보낼 수는 없지만,
--        굳이 열어 둘 이유도 없다)
-- ------------------------------------------------------------
create table if not exists push_tokens (
  -- Expo 가 발급하는 "ExponentPushToken[xxxxxxxx]" 형태
  token        text primary key check (length(token) between 10 and 255),
  user_id      uuid not null references profiles(id) on delete cascade,
  platform     text not null check (platform in ('ios', 'android')),
  created_at   timestamptz not null default now(),
  -- 앱을 열 때마다 갱신된다. 오래된 기기를 정리할 때 쓴다.
  last_seen_at timestamptz not null default now()
);

comment on table push_tokens is
  '기기 푸시 토큰. 쓰기는 save_push_token / delete_push_token 으로만 (마이그레이션 013)';

create index if not exists idx_push_tokens_user on push_tokens(user_id);

alter table push_tokens enable row level security;

drop policy if exists push_tokens_select        on push_tokens;
drop policy if exists push_tokens_insert_denied on push_tokens;
drop policy if exists push_tokens_update_denied on push_tokens;
drop policy if exists push_tokens_delete_denied on push_tokens;

create policy push_tokens_select on push_tokens for select to authenticated
using (user_id = auth.uid() or is_admin());

-- 012 의 notifications 와 같은 이유로 직접 쓰기는 전부 막는다.
-- 직접 열면 남의 uuid 로 토큰을 등록해 그 사람 알림을 가로챌 수 있다.
create policy push_tokens_insert_denied on push_tokens for insert to authenticated
with check (false);

create policy push_tokens_update_denied on push_tokens for update to authenticated
using (false);

create policy push_tokens_delete_denied on push_tokens for delete to authenticated
using (false);

grant select on push_tokens to authenticated;


-- ------------------------------------------------------------
-- 2. 토큰 등록 / 해제 — 앱이 부르는 RPC
--
--    등록은 앱을 켤 때마다 부른다(토큰은 재설치·업데이트로 바뀔 수 있다).
--    해제는 로그아웃 때 부른다 — 안 하면 기기를 넘겨준 뒤에도 이전 사람의
--    알림이 그 기기로 계속 간다.
-- ------------------------------------------------------------
create or replace function save_push_token(p_token text, p_platform text)
returns void language plpgsql security definer
set search_path = public as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception '로그인이 필요합니다' using errcode = 'insufficient_privilege';
  end if;

  if p_platform not in ('ios', 'android') then
    raise exception '알 수 없는 기기입니다' using errcode = 'check_violation';
  end if;

  -- Expo 토큰 형태만 받는다. 아무 문자열이나 쌓이면 발송 때마다 실패한다.
  if p_token !~ '^Expo(nent)?PushToken\[.+\]$' then
    raise exception '알림 토큰 형식이 올바르지 않습니다' using errcode = 'check_violation';
  end if;

  insert into push_tokens (token, user_id, platform)
  values (p_token, v_user, p_platform)
  on conflict (token) do update
    set user_id      = excluded.user_id,     -- 기기 주인이 바뀐 경우
        platform     = excluded.platform,
        last_seen_at = now();
end; $$;

create or replace function delete_push_token(p_token text)
returns void language sql security definer
set search_path = public as $$
  delete from push_tokens
  where token = p_token and user_id = auth.uid();
$$;

revoke all on function save_push_token(text, text) from public;
revoke all on function delete_push_token(text)     from public;
grant execute on function save_push_token(text, text) to authenticated;
grant execute on function delete_push_token(text)     to authenticated;


-- ------------------------------------------------------------
-- 3. 발송 트리거 (after insert on notifications)
--
--    pg_net 은 요청을 큐에 넣고 바로 돌아온다(비동기). 그래서 Expo 서버가
--    느리거나 죽어 있어도 매칭 수락 트랜잭션이 그만큼 늘어지지 않는다.
--
--    ⚠️ 전체를 exception 으로 감싼 것이 이 함수의 핵심이다.
--       pg_net 이 없거나, Vault 에 키가 없거나, 함수 이름이 바뀌었거나 —
--       무엇이 잘못되든 여기서 예외가 올라가면 notifications insert 가
--       실패하고, 그러면 그 insert 를 부른 매칭 수락까지 통째로 롤백된다.
--       푸시 한 통 때문에 매칭이 깨지는 것보다 푸시를 못 보내는 편이 낫다.
--
--    ⚠️ 재시도는 없다. 요청이 유실되면 그 알림의 푸시는 그걸로 끝이다.
--       알림 자체는 notifications 에 남아 있으므로 앱을 열면 보인다.
-- ------------------------------------------------------------
create or replace function dispatch_push_notification()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_url text;
  v_key text;
begin
  -- 등록된 기기가 없는 사람이면 부를 것도 없다. 대부분의 알림이 여기서 끝난다
  -- (웹에서만 쓰거나, 알림 권한을 거부한 사람).
  if not exists (select 1 from push_tokens where user_id = new.user_id) then
    return null;
  end if;

  begin
    select decrypted_secret into v_url
    from vault.decrypted_secrets where name = 'project_url';

    select decrypted_secret into v_key
    from vault.decrypted_secrets where name = 'service_role_key';

    -- 아직 준비가 안 된 프로젝트(4번을 안 돌렸다). 조용히 넘어간다.
    if v_url is null or v_key is null then
      return null;
    end if;

    perform net.http_post(
      url     := v_url || '/functions/v1/send-push',
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'Authorization', 'Bearer ' || v_key
      ),
      -- 내용은 보내지 않는다. 함수가 id 로 직접 읽는 편이 안전하다 —
      -- 여기서 실어 보낸 문구와 저장된 문구가 어긋날 일이 없다.
      body    := jsonb_build_object('notification_id', new.id)
    );

  exception when others then
    raise warning '[push] 발송 요청 실패 (알림 %): %', new.id, sqlerrm;
  end;

  return null;
end; $$;

drop trigger if exists notifications_dispatch_push on notifications;
create trigger notifications_dispatch_push
after insert on notifications
for each row execute function dispatch_push_notification();


-- ------------------------------------------------------------
-- 4. 준비물 — 여기부터는 한 번만, 손으로 한다
--
--    아래 세 가지가 갖춰지기 전까지 3번 트리거는 아무 일도 하지 않는다.
-- ------------------------------------------------------------

-- (1) pg_net — 트리거가 HTTP 요청을 걸 수 있게 한다.
--     Dashboard → Database → Extensions 에서 pg_net 을 켜도 같다.
create extension if not exists pg_net;

-- (2) Vault 에 주소와 열쇠를 넣는다.
--     ⚠️ 서버 열쇠는 RLS 를 통째로 지나간다. 앱이나 git 에 절대 두지 말 것.
--        Vault 는 암호화해서 보관하고, 위 트리거처럼 security definer 함수
--        안에서만 꺼내 쓴다.
--
--     아래 두 줄의 값을 채워서 SQL Editor 에 한 번만 실행한다.
--       project_url      : Dashboard → Settings → API → Project URL
--                          (예: https://abcdefgh.supabase.co, 끝에 / 없이)
--       service_role_key : Dashboard → Settings → API Keys 의 비밀 키.
--                          이 프로젝트는 새 형식이라 "sb_secret_..." 이다
--                          (예전 프로젝트는 JWT 모양의 service_role).
--                          send-push 가 자기 환경변수와 대조하므로 반드시
--                          같은 값이어야 한다 — 다르면 403 으로 막힌다.
--
-- select vault.create_secret('https://<프로젝트>.supabase.co', 'project_url');
-- select vault.create_secret('<service_role_key>', 'service_role_key');
--
--     다시 넣을 때(키를 새로 발급했다면)는 update 다. create 를 또 하면
--     같은 이름이 두 개가 되고 위 트리거의 select 가 둘 중 하나를 집는다.
-- select vault.update_secret(
--          (select id from vault.secrets where name = 'service_role_key'),
--          '<새 service_role_key>');

-- (3) Edge Function 배포
--     supabase functions deploy send-push
--
--     config.toml 의 [functions.send-push] 가 verify_jwt = false 로 잡혀
--     있다(함수가 직접 열쇠를 대조한다). 배포 명령이 그 설정을 읽는다.
--
--     ⚠️ 앱 쪽 준비물도 하나 더 있다 — EAS projectId.
--        `eas init` 을 돌리지 않으면 기기가 토큰 자체를 못 받아서
--        push_tokens 가 계속 비어 있고, 그러면 이 트리거는 늘 3번의
--        첫 줄에서 조용히 끝난다. (frontend/lib/push.ts 참고)


-- ------------------------------------------------------------
-- 5. 확인
-- ------------------------------------------------------------
-- -- (1) 기기가 등록되고 있나
-- select p.login_id, t.platform, t.created_at, t.last_seen_at
-- from push_tokens t join profiles p on p.id = t.user_id
-- order by t.last_seen_at desc;
--
-- -- (2) Vault 준비가 끝났나 (두 줄이 나와야 한다)
-- select name, created_at from vault.secrets
-- where name in ('project_url', 'service_role_key');
--
-- -- (3) 요청이 실제로 나갔나 — pg_net 의 응답 기록
-- --     status_code 가 200 이어야 한다. 401 이면 service_role_key 가 틀렸고,
-- --     404 면 함수가 아직 배포되지 않았다.
-- select id, status_code, content, created
-- from net._http_response
-- order by id desc
-- limit 10;
--
-- -- (4) 나에게 시험 알림 한 줄 넣어보기 — 푸시가 오는지 보는 가장 빠른 방법.
-- --     SQL Editor 는 postgres 로 붙어 RLS 를 지나가므로 그냥 넣으면 되고,
-- --     insert 가 곧 사건이라 위 3번 트리거도 그대로 돈다.
-- --     (broadcast_notice() 는 여기서 부를 수 없다 — auth.uid() 가 null 이라
-- --      is_admin() 이 항상 false 다. 자세한 것은 마이그레이션 012 참고)
-- insert into notifications (user_id, kind, title, body)
-- select id, 'NOTICE', '시험 알림', '푸시가 도착하면 성공입니다.'
-- from profiles
-- where login_id = '<내아이디>';
--
-- -- (5) 오래 안 쓰는 기기 정리 — 필요해지면 pg_cron 으로 돌린다.
-- --     (죽은 토큰은 send-push 가 발송 실패 응답을 보고 스스로 지운다)
-- -- delete from push_tokens where last_seen_at < now() - interval '180 days';
