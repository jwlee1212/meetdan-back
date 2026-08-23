-- ============================================================
-- 마이그레이션 011 — 메시지는 Edge Function 을 통해서만 들어간다
--
-- 문제
--   messages_insert 정책(schema_v2 :533)은 클라이언트의 직접 insert 를
--   허용한다. 그래서 filter-message Edge Function 은 "불러도 되고 안 불러도
--   되는" 검사기였다. 앱을 조금만 뜯어보면
--
--     supabase.from('messages').insert({ room_id, sender_id, kind:'user',
--                                        content:'<욕설>', is_filtered:false })
--
--   한 줄로 필터를 통째로 건너뛸 수 있다. is_filtered / filter_note 도
--   클라이언트가 아무 값이나 넣을 수 있어서, 신고 처리 화면이 그 값을 믿고
--   판단하면 그대로 속는다.
--
--   Apple 심사 지침 1.2(사용자 생성 콘텐츠 필터링)는 '필터가 있다'가 아니라
--   '거를 수 없다'를 본다. 우회 가능한 필터는 없는 것과 같다.
--
-- 해결
--   메시지가 들어가는 길을 하나로 좁힌다.
--
--     앱 → filter-message Edge Function → send_chat_message() → messages
--
--   1. send_chat_message() : 참여자·개방·계정 상태를 전부 다시 확인하고 넣는
--      security definer 함수. authenticated 에게는 실행 권한을 주지 않는다.
--      service_role(= Edge Function 만 가진 키)만 부를 수 있다.
--   2. messages_insert 정책을 거짓으로 바꿔 직접 insert 를 막는다.
--
--   그 결과 is_filtered / filter_note 는 Edge Function 만 쓸 수 있는 값이 된다.
--
-- 왜 RLS 정책이 아니라 함수에서 검사하는가
--   service_role 은 RLS 를 통과해 버린다(bypassrls). Edge Function 이
--   service_role 로 insert 하는 순간 정책은 아무 말도 하지 않으므로,
--   지금까지 정책이 하던 검사(is_room_participant / is_room_open /
--   is_account_active)를 함수 안에서 그대로 한 번 더 한다.
--   기존 헬퍼는 auth.uid() 를 보는데 service_role 호출에는 그런 게 없어서,
--   보내는 사람을 인자로 받아 같은 조건을 직접 쓴다.
--
-- 시스템 메시지는 그대로다
--   post_system_message / post_exit_proposal 은 security definer 라 테이블
--   소유자(postgres) 권한으로 돌고, 소유자에게는 RLS 가 적용되지 않는다.
--   원래도 messages_insert 정책(kind = 'user' 요구)을 통과한 적이 없다.
--   이번 변경의 영향을 받지 않는다.
--
-- Edge Function 이름은 filter-message 그대로 두었다
--   하는 일이 '거르기'에서 '거르고 넣기'로 넓어졌지만, 이름을 바꾸면
--   배포된 함수 주소가 바뀌고 schema_v2 의 주석 두 곳이 어긋난다.
--   이름값보다 그쪽 비용이 커서 유지했다.
--
-- 실행: Supabase Dashboard → SQL Editor 에 통째로 붙여넣고 Run
--       (전제: dku_meeting_schema_v2.sql + 마이그레이션 002~010)
--       ⚠ 이 마이그레이션을 적용한 뒤에는 filter-message 를 반드시 함께
--         배포해야 한다. 안 그러면 채팅이 통째로 막힌다.
--         supabase functions deploy filter-message
-- ============================================================


-- ------------------------------------------------------------
-- 1. 전송 함수
--
--    p_message_id 를 클라이언트가 만들어 보낸다. Realtime 은 내가 보낸
--    메시지도 되돌려주는데, id 가 미리 정해져 있으면 화면에 먼저 그려둔
--    말풍선과 그냥 겹쳐 쓰면 되어 임시 id 치환 로직이 사라진다.
--
--    같은 id 로 두 번 들어오면(전송 후 응답을 못 받아 재시도한 경우) 새로
--    넣지 않고 원래 행을 돌려준다. 네트워크가 끊겼다 붙을 때 같은 말이
--    두 번 뜨는 걸 여기서 막는다.
-- ------------------------------------------------------------
create or replace function send_chat_message(
  p_room_id     uuid,
  p_sender_id   uuid,
  p_content     text,
  p_is_filtered boolean default false,
  p_filter_note text    default null,
  p_message_id  uuid    default null
)
returns messages
language plpgsql security definer
set search_path = public as $$
declare
  v_id  uuid := coalesce(p_message_id, gen_random_uuid());
  v_row messages%rowtype;
begin
  -- 방 참여자인가 (is_room_participant 와 같은 조건, 주체만 인자로 받는다)
  if not exists (
    select 1
    from chat_rooms r
    join matches m       on m.id = r.match_id
    join team_members tm on tm.team_id in (m.from_team_id, m.to_team_id)
    where r.id = p_room_id and tm.user_id = p_sender_id
  ) then
    raise exception '이 채팅방의 참여자가 아닙니다' using errcode = 'check_violation';
  end if;

  -- 아직 열려 있는 방인가 (종료 제안에 양쪽이 동의하면 closed_at 이 찬다)
  if not exists (
    select 1 from chat_rooms where id = p_room_id and closed_at is null
  ) then
    raise exception '이미 종료된 채팅방입니다' using errcode = 'check_violation';
  end if;

  -- 정지·탈퇴·미인증 계정은 보낼 수 없다 (is_account_active 와 같은 조건)
  if not exists (
    select 1 from profiles
    where id = p_sender_id
      and status in ('active', 'warned')
      and deleted_at is null
      and email_verified_at is not null
  ) then
    raise exception '메시지를 보낼 수 없는 계정입니다' using errcode = 'check_violation';
  end if;

  insert into messages (id, room_id, sender_id, kind, content, is_filtered, filter_note)
  values (v_id, p_room_id, p_sender_id, 'user', p_content,
          coalesce(p_is_filtered, false), nullif(p_filter_note, ''))
  on conflict (id) do nothing
  returning * into v_row;

  if v_row.id is null then
    -- 이미 있는 id 다. 내가 이 방에 보낸 그 메시지면 재시도로 보고 돌려준다.
    select * into v_row from messages
     where id = v_id and room_id = p_room_id and sender_id = p_sender_id;

    -- 남의 메시지 id 를 들고 온 경우다. 조용히 성공시키면 클라이언트가
    -- 엉뚱한 메시지를 '내가 보낸 것'으로 그린다.
    if not found then
      raise exception '메시지 id 가 중복되었습니다' using errcode = 'unique_violation';
    end if;
  end if;

  return v_row;
end; $$;

-- 이 함수의 존재 이유가 곧 권한 설정이다.
-- authenticated 가 부를 수 있으면 필터를 건너뛰는 길이 다시 열린다.
revoke all on function send_chat_message(uuid, uuid, text, boolean, text, uuid) from public;
revoke all on function send_chat_message(uuid, uuid, text, boolean, text, uuid) from anon;
revoke all on function send_chat_message(uuid, uuid, text, boolean, text, uuid) from authenticated;
grant execute on function send_chat_message(uuid, uuid, text, boolean, text, uuid) to service_role;


-- ------------------------------------------------------------
-- 2. 직접 insert 차단
--
--    정책을 지우기만 해도 insert 는 막힌다(정책이 없으면 아무것도 통과하지
--    못한다). 그런데 그러면 정책 목록에서 '일부러 막은 것'과 '깜빡 잊고 안
--    만든 것'이 구분되지 않는다. 항상 거짓인 정책을 대신 세워 둔다.
-- ------------------------------------------------------------
--    create policy 에는 if not exists 가 없다. 이 파일을 두 번 돌려도
--    42710(already exists)으로 멈추지 않게 지우고 다시 만든다.
drop policy if exists messages_insert        on messages;
drop policy if exists messages_insert_denied on messages;

create policy messages_insert_denied on messages for insert to authenticated
with check (false);

comment on policy messages_insert_denied on messages is
  '메시지는 filter-message Edge Function → send_chat_message() 로만 들어온다 (마이그레이션 011)';


-- ------------------------------------------------------------
-- 3. 확인
--
--    앱에서 채팅을 한 줄 보낸 뒤 아래를 돌려본다.
-- ------------------------------------------------------------
-- -- (1) 정책이 바뀌었나 — messages_insert_denied 하나만 남아야 한다
-- select polname, pg_get_expr(polwithcheck, polrelid) as with_check
-- from pg_policy
-- where polrelid = 'messages'::regclass and polcmd = 'a';
--
-- -- (2) 권한이 service_role 에만 있나
-- select grantee, privilege_type
-- from information_schema.routine_privileges
-- where routine_name = 'send_chat_message';
--
-- -- (3) authenticated 로 직접 넣으면 막히는가 (42501 이 나와야 정상)
-- --     set local role authenticated;
-- --     select set_config('request.jwt.claims', '{"sub":"<내 uuid>","role":"authenticated"}', true);
-- --     insert into messages (room_id, sender_id, kind, content)
-- --     values ('<room uuid>', '<내 uuid>', 'user', '직접 넣기');
--
-- -- (4) 마스킹된 메시지가 실제로 표시되고 있나
-- select id, content, is_filtered, filter_note, created_at
-- from messages
-- where is_filtered
-- order by created_at desc
-- limit 20;
