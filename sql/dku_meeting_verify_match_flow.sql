-- ============================================================
-- 검증 — 팀 · 팀원 · 매칭 · 채팅방에 걸친 트리거 연쇄
--
-- 무엇을 하는가
--   실제 계정 11개와 팀 7개를 만들어 가입 → 팀 생성 → 초대 코드 참여 →
--   게시판 공개 → 신청 → 거절 → 수락 → 채팅방 생성 → 자동 거절까지
--   앱과 똑같은 순서로 밟는다. 각 단계에서 트리거가 남겼어야 할 값을
--   전부 확인하고, 막았어야 할 요청이 실제로 막히는지도 확인한다.
--
--   모든 쿼리는 앱과 같은 조건에서 돈다.
--     set local role authenticated + request.jwt.claims
--   즉 RLS 정책도 함께 검증된다. (postgres 로 그냥 돌리면 정책이 통째로
--    무시되어 "되더라"는 결과만 나온다.)
--
-- 어떤 문장도 스크립트를 중간에 끊지 않는다
--   확인(verify_check) · 막힘(verify_blocked) · 실행(verify_run) 세 가지로만
--   되어 있고, 셋 다 실패를 기록만 하고 넘어간다. 그래서 앞 단계가 실패해도
--   끝까지 돌아 보고서가 나온다. 실행문은 실패했을 때만 한 줄 남는다.
--
--   특히 verify_blocked 는 '막혔어야 할 문장이 통과해 버린' 경우 그 변경을
--   되돌린다. 안 그러면 통과해버린 쓰기가 그대로 남아, 한참 뒤 엉뚱한
--   단계에서 알 수 없는 오류로 터진다.
--
-- ⚠️ 데이터는 남지 않는다
--   전체가 하나의 트랜잭션이고, 마지막에 일부러 예외를 던져 롤백한다.
--   **결과 보고서는 그 예외 메시지 안에 들어 있다.** SQL Editor 가
--   빨간 오류 상자로 보여주는 그 내용이 곧 결과다.
--   (psql 로 돌리면 NOTICE 로도 같은 줄이 흐른다.)
--
-- 실행: Supabase Dashboard → SQL Editor 에 통째로 붙여넣고 Run
--       전제: dku_meeting_schema_v2.sql + 마이그레이션 002~010
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 0. 기록 도구
--
--    verify_log 만 security definer 다(기록은 postgres 로 남긴다).
--    나머지는 호출하는 쪽 권한(authenticated)으로 돌아야 RLS 를 함께 본다.
--
--    임시 스키마(pg_temp) 대신 public 에 만든다. set role 로 역할을
--    바꿔 가며 부르는데, 남의 역할에서 임시 스키마 접근이 막힐 수 있다.
--    이 네 개도 트랜잭션과 함께 사라진다.
-- ------------------------------------------------------------
create table public.verify_t_log (
  seq    serial primary key,
  step   text,
  ok     boolean,
  detail text
);

create function public.verify_log(p_step text, p_ok boolean, p_detail text)
returns void language plpgsql security definer as $$
begin
  insert into public.verify_t_log (step, ok, detail) values (p_step, p_ok, p_detail);
  if p_ok then
    raise notice '  OK   %  %', p_step, coalesce(p_detail, '');
  else
    raise warning '  FAIL %  %', p_step, coalesce(p_detail, '');
  end if;
end $$;

-- 조건 하나를 확인한다. 인자는 부르는 쪽 권한으로 계산된다.
create function public.verify_check(p_step text, p_ok boolean, p_detail text default null)
returns void language plpgsql security invoker as $$
begin
  perform public.verify_log(p_step, coalesce(p_ok, false), p_detail);
end $$;

-- 성공해야 하는 문장. 실패하면 기록만 하고 다음으로 넘어간다.
-- (그냥 써두면 첫 실패에서 트랜잭션이 끊겨 보고서 자체가 사라진다)
create function public.verify_run(p_step text, p_sql text)
returns void language plpgsql security invoker as $$
begin
  execute p_sql;
exception when others then
  perform public.verify_log('[실행 실패] ' || p_step, false,
    format('%s (SQLSTATE %s)', sqlerrm, sqlstate));
end $$;

-- 막혀야 하는 문장.
create function public.verify_blocked(p_step text, p_sql text, p_needle text)
returns void language plpgsql security invoker as $$
declare
  v_msg    text;
  v_ok     boolean;
  v_detail text;
begin
  begin
    execute p_sql;
    -- 여기까지 왔다 = 막히지 않았다. 일부러 예외를 던져 이 블록의 변경을
    -- 되돌린다. 통과해버린 쓰기를 그대로 두면 뒤 단계들이 엉뚱한 상태에서
    -- 돌다가 전혀 다른 곳에서 터진다.
    raise exception using message = '__verify_not_blocked__';
  exception when others then
    v_msg := sqlerrm;
    if v_msg = '__verify_not_blocked__' then
      v_ok     := false;
      v_detail := '막히지 않고 통과했다 (변경은 되돌렸다)';
    else
      v_ok     := position(p_needle in v_msg) > 0;
      v_detail := format('%s (SQLSTATE %s)', v_msg, sqlstate);
    end if;
  end;

  perform public.verify_log(p_step, v_ok, v_detail);
end $$;


-- ------------------------------------------------------------
-- 1. 계정 11개 — auth.users 에 넣으면 on_auth_user_created 가
--    profiles 를 만든다 (마이그레이션 002 + 006)
--
--    ⛓ 연쇄 1: auth.users INSERT → handle_new_user() → profiles INSERT
-- ------------------------------------------------------------
select public.verify_run('계정 11개 생성', $sql$
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select
  '00000000-0000-0000-0000-000000000000',
  u.id,
  'authenticated', 'authenticated',
  format('meetdan-verify-%s@dankook.ac.kr', u.n),
  'verify-script-placeholder-hash',
  now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object(
    'login_id',   format('vfy%s', u.n),
    'name',       format('검증계정%s', u.n),
    'gender',     u.gender,
    'campus',     '죽전',
    'dept',       u.dept,
    'birth_year', u.birth_year
  ),
  false
from (values
  ('01', '00000000-0000-4000-8000-000000000001'::uuid, 'M', '소프트웨어학과', 2002),
  ('02', '00000000-0000-4000-8000-000000000002'::uuid, 'M', '소프트웨어학과', 2000),
  ('03', '00000000-0000-4000-8000-000000000003'::uuid, 'F', '시각디자인과',   2001),
  ('04', '00000000-0000-4000-8000-000000000004'::uuid, 'F', '시각디자인과',   2003),
  ('05', '00000000-0000-4000-8000-000000000005'::uuid, 'M', '체육교육과',     2002),
  ('06', '00000000-0000-4000-8000-000000000006'::uuid, 'M', '체육교육과',     2002),
  ('07', '00000000-0000-4000-8000-000000000007'::uuid, 'F', '경영학과',       2002),
  ('08', '00000000-0000-4000-8000-000000000008'::uuid, 'F', '경영학과',       2002),
  ('09', '00000000-0000-4000-8000-000000000009'::uuid, 'F', '간호학과',       2002),
  ('10', '00000000-0000-4000-8000-000000000010'::uuid, 'F', '간호학과',       2002),
  ('11', '00000000-0000-4000-8000-000000000011'::uuid, 'F', '간호학과',       2002)
) as u(n, id, gender, dept, birth_year)
$sql$);

select public.verify_check(
  '1-1 가입 트리거가 profiles 11행을 만든다',
  (select count(*) = 11 from profiles
    where id between '00000000-0000-4000-8000-000000000001'
                 and '00000000-0000-4000-8000-000000000011'),
  format('%s행', (select count(*) from profiles
                   where id between '00000000-0000-4000-8000-000000000001'
                                and '00000000-0000-4000-8000-000000000011'))
);

select public.verify_check(
  '1-2 birth_year / email_verified_at 까지 채워진다',
  (select birth_year = 2002 and email_verified_at is not null
     from profiles where id = '00000000-0000-4000-8000-000000000001')
);


-- ------------------------------------------------------------
-- 2. 팀 생성 (u01) — 앱과 같은 권한으로
--
--    ⛓ 연쇄 2: teams INSERT
--        → (before) teams_set_invite_code  : 코드 발급
--        → (before) teams_set_owner_facts  : dept/gender/avg_age 복사
--        → (after)  teams_add_owner        : team_members INSERT
--            → (before) team_members_capacity_guard / gender_guard
--            → (after)  team_members_sync_avg_age → teams UPDATE
--            → (after)  team_members_sync_fill    → teams UPDATE
--                 → (before) teams_guard_avg_age / teams_guard_publish
-- ------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}', true);

select public.verify_run('팀 A 생성', $sql$
insert into teams (id, owner_id, title, content, campus, capacity, tags, invite_code)
values ('00000000-0000-4000-8000-0000000000a1',
        '00000000-0000-4000-8000-000000000001',
        '검증팀 A (남 2)', '트리거 검증용 팀입니다.', '죽전', 2,
        array['#검증'], 'TSTA01')
$sql$);

-- 코드를 안 보내면 서버가 만든다 (마이그레이션 004)
select public.verify_run('팀 F 생성 (코드 자동발급)', $sql$
insert into teams (id, owner_id, title, content, campus, capacity)
values ('00000000-0000-4000-8000-0000000000a6',
        '00000000-0000-4000-8000-000000000001',
        '검증팀 F (코드 자동발급)', '초대 코드 자동 발급 확인용.', '죽전', 2)
$sql$);

reset role;

select public.verify_check(
  '2-1 owner_facts: dept/gender 를 팀장 프로필에서 복사한다',
  (select dept = '소프트웨어학과' and gender = 'M'
     from teams where id = '00000000-0000-4000-8000-0000000000a1')
);

select public.verify_check(
  '2-2 owner_facts: avg_age = 팀장 세는나이',
  (select avg_age = korean_age(2002)
     from teams where id = '00000000-0000-4000-8000-0000000000a1'),
  format('avg_age=%s', (select avg_age from teams
                         where id = '00000000-0000-4000-8000-0000000000a1'))
);

select public.verify_check(
  '2-3 add_owner: 팀장이 team_members 에 is_owner 로 들어간다',
  (select is_owner from team_members
    where team_id = '00000000-0000-4000-8000-0000000000a1'
      and user_id = '00000000-0000-4000-8000-000000000001')
);

select public.verify_check(
  '2-4 sync_fill: filled_count=1, status=RECRUITING',
  (select filled_count = 1 and status = 'RECRUITING'
     from teams where id = '00000000-0000-4000-8000-0000000000a1'),
  format('filled=%s status=%s',
    (select filled_count from teams where id = '00000000-0000-4000-8000-0000000000a1'),
    (select status       from teams where id = '00000000-0000-4000-8000-0000000000a1'))
);

select public.verify_check(
  '2-5 invite_code: 서버가 6자리 코드를 발급한다',
  (select invite_code ~ '^[A-Z0-9]{6}$'
     from teams where id = '00000000-0000-4000-8000-0000000000a6'),
  format('code=%s', (select invite_code from teams
                      where id = '00000000-0000-4000-8000-0000000000a6'))
);


-- ------------------------------------------------------------
-- 3. 나머지 팀 5개 (B 여2 / C 남2 / D 여2 / E 여3) + G (남2, 성별 가드용)
-- ------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select public.verify_run('팀 B 생성', $sql$
insert into teams (id, owner_id, title, content, campus, capacity, invite_code)
values ('00000000-0000-4000-8000-0000000000a2', '00000000-0000-4000-8000-000000000003',
        '검증팀 B (여 2)', '검증용', '죽전', 2, 'TSTB01')
$sql$);

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
select public.verify_run('팀 C 생성', $sql$
insert into teams (id, owner_id, title, content, campus, capacity, invite_code)
values ('00000000-0000-4000-8000-0000000000a3', '00000000-0000-4000-8000-000000000005',
        '검증팀 C (남 2)', '검증용', '죽전', 2, 'TSTC01')
$sql$);

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000007","role":"authenticated"}', true);
select public.verify_run('팀 D 생성', $sql$
insert into teams (id, owner_id, title, content, campus, capacity, invite_code)
values ('00000000-0000-4000-8000-0000000000a4', '00000000-0000-4000-8000-000000000007',
        '검증팀 D (여 2)', '검증용', '죽전', 2, 'TSTD01')
$sql$);

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000009","role":"authenticated"}', true);
select public.verify_run('팀 E 생성', $sql$
insert into teams (id, owner_id, title, content, campus, capacity, invite_code)
values ('00000000-0000-4000-8000-0000000000a5', '00000000-0000-4000-8000-000000000009',
        '검증팀 E (여 3)', '검증용', '죽전', 3, 'TSTE01')
$sql$);

-- G 는 자리를 하나 비워 둔다. 정원이 차 있으면 capacity_guard 가 먼저
-- 걸려서 성별 가드(마이그레이션 010)를 확인할 수 없다.
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select public.verify_run('팀 G 생성', $sql$
insert into teams (id, owner_id, title, content, campus, capacity, invite_code)
values ('00000000-0000-4000-8000-0000000000a7', '00000000-0000-4000-8000-000000000001',
        '검증팀 G (남 2, 자리 있음)', '검증용', '죽전', 2, 'TSTG01')
$sql$);
reset role;


-- ------------------------------------------------------------
-- 4. 초대 코드로 참여
--
--    ⛓ 연쇄 3: join_team_by_code() → team_members INSERT
--        → capacity_guard → gender_guard → sync_avg_age → sync_fill
-- ------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
select public.verify_run('u02 → 팀 A 참여', $sql$select join_team_by_code('TSTA01')$sql$);

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000004","role":"authenticated"}', true);
select public.verify_run('u04 → 팀 B 참여', $sql$select join_team_by_code('TSTB01')$sql$);

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000006","role":"authenticated"}', true);
select public.verify_run('u06 → 팀 C 참여', $sql$select join_team_by_code('TSTC01')$sql$);

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000008","role":"authenticated"}', true);
select public.verify_run('u08 → 팀 D 참여', $sql$select join_team_by_code('TSTD01')$sql$);

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000010","role":"authenticated"}', true);
select public.verify_run('u10 → 팀 E 참여', $sql$select join_team_by_code('TSTE01')$sql$);

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000011","role":"authenticated"}', true);
select public.verify_run('u11 → 팀 E 참여', $sql$select join_team_by_code('TSTE01')$sql$);

-- 같은 사람이 또 들어가려 하면 RPC 가 막는다
select public.verify_blocked(
  '4-1 이미 참여한 팀에 다시 참여할 수 없다',
  $sql$select join_team_by_code('TSTE01')$sql$,
  '이미 참여한 팀입니다');
reset role;

select public.verify_check(
  '4-2 sync_fill: 정원이 차면 READY 로 올라간다',
  (select filled_count = 2 and status = 'READY'
     from teams where id = '00000000-0000-4000-8000-0000000000a1'),
  format('filled=%s status=%s',
    (select filled_count from teams where id = '00000000-0000-4000-8000-0000000000a1'),
    (select status       from teams where id = '00000000-0000-4000-8000-0000000000a1'))
);

select public.verify_check(
  '4-3 sync_avg_age: 팀원 둘의 평균으로 다시 계산된다',
  (select avg_age = round((korean_age(2002) + korean_age(2000))::numeric / 2)::int
     from teams where id = '00000000-0000-4000-8000-0000000000a1'),
  format('avg_age=%s', (select avg_age from teams
                         where id = '00000000-0000-4000-8000-0000000000a1'))
);

-- 정원이 찬 팀에는 더 들어갈 수 없다 (team_members_capacity_guard)
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
select public.verify_blocked(
  '4-4 capacity_guard: 정원이 찬 팀에는 못 들어간다',
  $sql$select join_team_by_code('TSTA01')$sql$,
  '팀 정원이 가득 찼습니다');
reset role;

-- 이성은 초대 코드를 알아도 못 들어간다 (마이그레이션 010)
-- G 는 남자 팀이고 자리가 하나 남아 있다.
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select public.verify_blocked(
  '4-5 gender_guard: 이성은 초대 코드로도 팀에 못 들어간다',
  $sql$select join_team_by_code('TSTG01')$sql$,
  '같은 성별끼리만 팀을 이룰 수 있습니다');
reset role;

-- 같은 성별은 그대로 들어간다 (가드가 정상 참여까지 막지 않는지)
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
select public.verify_run('u05 → 팀 G 참여', $sql$select join_team_by_code('TSTG01')$sql$);
reset role;

select public.verify_check(
  '4-6 gender_guard: 같은 성별은 정상 참여한다',
  (select filled_count = 2 from teams
    where id = '00000000-0000-4000-8000-0000000000a7'),
  format('filled=%s', (select filled_count from teams
                        where id = '00000000-0000-4000-8000-0000000000a7'))
);

select public.verify_check(
  '4-7 검증 팀 7개 모두 동성으로만 채워졌다',
  not exists (
    select 1
    from team_members m
    join teams t    on t.id = m.team_id
    join profiles p on p.id = m.user_id
    where t.id between '00000000-0000-4000-8000-0000000000a1'
                   and '00000000-0000-4000-8000-0000000000a7'
      and p.gender <> t.gender
  )
);


-- ------------------------------------------------------------
-- 5. 게시판 공개 (teams_guard_publish)
-- ------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}', true);

-- 인원이 안 찬 팀(F)은 공개할 수 없다
select public.verify_blocked(
  '5-1 guard_publish: 정원 미달 팀은 공개 불가',
  $sql$update teams set status = 'ACTIVE' where id = '00000000-0000-4000-8000-0000000000a6'$sql$,
  '팀원이 다 모여야');

select public.verify_run('팀 A 공개', $sql$
update teams set status = 'ACTIVE' where id = '00000000-0000-4000-8000-0000000000a1'
$sql$);

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select public.verify_run('팀 B 공개', $sql$
update teams set status = 'ACTIVE' where id = '00000000-0000-4000-8000-0000000000a2'
$sql$);

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
select public.verify_run('팀 C 공개', $sql$
update teams set status = 'ACTIVE' where id = '00000000-0000-4000-8000-0000000000a3'
$sql$);

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000007","role":"authenticated"}', true);
select public.verify_run('팀 D 공개', $sql$
update teams set status = 'ACTIVE' where id = '00000000-0000-4000-8000-0000000000a4'
$sql$);

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000009","role":"authenticated"}', true);
select public.verify_run('팀 E 공개', $sql$
update teams set status = 'ACTIVE' where id = '00000000-0000-4000-8000-0000000000a5'
$sql$);
reset role;

select public.verify_check(
  '5-2 다섯 팀이 게시판에 올라갔다',
  (select count(*) = 5 from teams
    where id in ('00000000-0000-4000-8000-0000000000a1','00000000-0000-4000-8000-0000000000a2',
                 '00000000-0000-4000-8000-0000000000a3','00000000-0000-4000-8000-0000000000a4',
                 '00000000-0000-4000-8000-0000000000a5')
      and status = 'ACTIVE'),
  format('%s개', (select count(*) from teams
                   where id in ('00000000-0000-4000-8000-0000000000a1','00000000-0000-4000-8000-0000000000a2',
                                '00000000-0000-4000-8000-0000000000a3','00000000-0000-4000-8000-0000000000a4',
                                '00000000-0000-4000-8000-0000000000a5')
                     and status = 'ACTIVE'))
);


-- ------------------------------------------------------------
-- 6. [마이그레이션 009-6] 팀원이 빠지면 게시판에서 내려간다
--
--    ⛓ 연쇄 4: team_members DELETE → sync_fill → teams UPDATE
-- ------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
select public.verify_run('u02 팀 A 나가기', $sql$
delete from team_members
 where team_id = '00000000-0000-4000-8000-0000000000a1'
   and user_id = '00000000-0000-4000-8000-000000000002'
$sql$);
reset role;

select public.verify_check(
  '6-1 공개중이던 팀이 정원 미달이 되면 RECRUITING 으로 내려온다',
  (select filled_count = 1 and status = 'RECRUITING'
     from teams where id = '00000000-0000-4000-8000-0000000000a1'),
  format('filled=%s status=%s',
    (select filled_count from teams where id = '00000000-0000-4000-8000-0000000000a1'),
    (select status       from teams where id = '00000000-0000-4000-8000-0000000000a1'))
);

-- 인원이 모자란 팀은 신청도 못 한다
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select public.verify_blocked(
  '6-2 인원 미달 팀은 신청할 수 없다',
  $sql$insert into matches (from_team_id, to_team_id)
    values ('00000000-0000-4000-8000-0000000000a1','00000000-0000-4000-8000-0000000000a2')$sql$,
  '우리 팀 인원이 다 모여야');
reset role;

-- 다시 채우고 다시 공개
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
select public.verify_run('u02 팀 A 재참여', $sql$select join_team_by_code('TSTA01')$sql$);

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select public.verify_run('팀 A 재공개', $sql$
update teams set status = 'ACTIVE' where id = '00000000-0000-4000-8000-0000000000a1'
$sql$);
reset role;

select public.verify_check(
  '6-3 다시 채우고 공개하면 ACTIVE 로 돌아온다',
  (select filled_count = 2 and status = 'ACTIVE'
     from teams where id = '00000000-0000-4000-8000-0000000000a1'),
  format('filled=%s status=%s',
    (select filled_count from teams where id = '00000000-0000-4000-8000-0000000000a1'),
    (select status       from teams where id = '00000000-0000-4000-8000-0000000000a1'))
);


-- ------------------------------------------------------------
-- 7. [마이그레이션 009-4] 신청 유효성
-- ------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}', true);

select public.verify_blocked(
  '7-1 동성 팀에는 신청할 수 없다 (A 남 → C 남)',
  $sql$insert into matches (from_team_id, to_team_id)
    values ('00000000-0000-4000-8000-0000000000a1','00000000-0000-4000-8000-0000000000a3')$sql$,
  '이성 팀에만');

select public.verify_blocked(
  '7-2 인원 수가 다른 팀에는 신청할 수 없다 (A 2명 → E 3명)',
  $sql$insert into matches (from_team_id, to_team_id)
    values ('00000000-0000-4000-8000-0000000000a1','00000000-0000-4000-8000-0000000000a5')$sql$,
  '인원 수가 같은 팀');

select public.verify_blocked(
  '7-3 비공개 팀에는 신청할 수 없다 (F)',
  $sql$insert into matches (from_team_id, to_team_id)
    values ('00000000-0000-4000-8000-0000000000a1','00000000-0000-4000-8000-0000000000a6')$sql$,
  '게시판에 공개된 팀');
reset role;

-- 팀장이 아닌 사람은 신청 자체가 정책에 막힌다 (matches_insert)
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
select public.verify_blocked(
  '7-4 팀원(비팀장)은 신청할 수 없다 — RLS',
  $sql$insert into matches (from_team_id, to_team_id)
    values ('00000000-0000-4000-8000-0000000000a1','00000000-0000-4000-8000-0000000000a2')$sql$,
  'row-level security');
reset role;


-- ------------------------------------------------------------
-- 8. 신청 4건 — A→B(수락 예정) / A→D(거절 예정) / C→B / D→A
-- ------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select public.verify_run('신청 A→B', $sql$
insert into matches (id, from_team_id, to_team_id)
values ('00000000-0000-4000-8000-0000000000b1',
        '00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000a2')
$sql$);

select public.verify_run('신청 A→D', $sql$
insert into matches (id, from_team_id, to_team_id)
values ('00000000-0000-4000-8000-0000000000b4',
        '00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000a4')
$sql$);

-- 같은 팀에 두 번은 못 보낸다 (matches_no_duplicate_waiting)
select public.verify_blocked(
  '8-1 같은 팀에 대기중 신청은 하나뿐이다',
  $sql$insert into matches (from_team_id, to_team_id)
    values ('00000000-0000-4000-8000-0000000000a1','00000000-0000-4000-8000-0000000000a2')$sql$,
  'matches_no_duplicate_waiting');

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
select public.verify_run('신청 C→B', $sql$
insert into matches (id, from_team_id, to_team_id)
values ('00000000-0000-4000-8000-0000000000b2',
        '00000000-0000-4000-8000-0000000000a3', '00000000-0000-4000-8000-0000000000a2')
$sql$);

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000007","role":"authenticated"}', true);
select public.verify_run('신청 D→A', $sql$
insert into matches (id, from_team_id, to_team_id)
values ('00000000-0000-4000-8000-0000000000b3',
        '00000000-0000-4000-8000-0000000000a4', '00000000-0000-4000-8000-0000000000a1')
$sql$);
reset role;

select public.verify_check(
  '8-2 신청 4건이 WAITING 으로 들어갔다',
  (select count(*) = 4 from matches
    where id in ('00000000-0000-4000-8000-0000000000b1','00000000-0000-4000-8000-0000000000b2',
                 '00000000-0000-4000-8000-0000000000b3','00000000-0000-4000-8000-0000000000b4')
      and status = 'WAITING'),
  format('%s건', (select count(*) from matches
                   where id in ('00000000-0000-4000-8000-0000000000b1','00000000-0000-4000-8000-0000000000b2',
                                '00000000-0000-4000-8000-0000000000b3','00000000-0000-4000-8000-0000000000b4')
                     and status = 'WAITING'))
);


-- ------------------------------------------------------------
-- 9. [마이그레이션 009-1] 신청한 팀이 받는 쪽에 보이는가
--
--    B 팀장(u03) 시점에서 A 팀 행과 A 팀원 행이 조회되어야 한다.
--    ('받은 신청' 목록과 상대 팀 프로필 화면이 이것 하나에 달려 있다)
-- ------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000003","role":"authenticated"}', true);

select public.verify_check(
  '9-1 teams_select: 신청을 보낸 팀의 행이 보인다',
  (select count(*) = 1 from teams where id = '00000000-0000-4000-8000-0000000000a1')
);

select public.verify_check(
  '9-2 team_members_select: 그 팀의 팀원 2명이 보인다',
  (select count(*) = 2 from team_members
    where team_id = '00000000-0000-4000-8000-0000000000a1'),
  format('%s행', (select count(*) from team_members
                   where team_id = '00000000-0000-4000-8000-0000000000a1'))
);

select public.verify_check(
  '9-3 matches_select: 받은 신청 2건이 보인다 (A→B, C→B)',
  (select count(*) = 2 from matches
    where to_team_id = '00000000-0000-4000-8000-0000000000a2'),
  format('%s행', (select count(*) from matches
                   where to_team_id = '00000000-0000-4000-8000-0000000000a2'))
);
reset role;

-- 아무 관계도 없는 사람에게는 여전히 안 보인다 (비공개 팀 F)
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000009","role":"authenticated"}', true);
select public.verify_check(
  '9-4 관계 없는 사람에게 비공개 팀은 여전히 안 보인다',
  (select count(*) = 0 from teams where id = '00000000-0000-4000-8000-0000000000a6')
);
reset role;


-- ------------------------------------------------------------
-- 10. 거절
-- ------------------------------------------------------------
-- 제3자(C 팀장)는 D→A 를 건드릴 수 없다 — 정책이 행 자체를 감춘다(오류 아님, 0행)
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
select public.verify_run('제3자 거절 시도 (0행이어야 한다)', $sql$
update matches set status = 'REJECTED'
 where id = '00000000-0000-4000-8000-0000000000b3'
$sql$);
reset role;

select public.verify_check(
  '10-1 제3자의 거절은 정책에 막혀 아무 일도 없다',
  (select status = 'WAITING' from matches
    where id = '00000000-0000-4000-8000-0000000000b3'),
  format('status=%s', (select status from matches
                        where id = '00000000-0000-4000-8000-0000000000b3'))
);

-- 신청 대상 바꿔치기 (BEFORE INSERT 가드를 건너뛰는 길)
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select public.verify_blocked(
  '10-2 대기중 신청의 상대 팀을 바꿔치기할 수 없다',
  $sql$update matches set to_team_id = '00000000-0000-4000-8000-0000000000a5'
     where id = '00000000-0000-4000-8000-0000000000b1'$sql$,
  '신청 대상은 바꿀 수 없습니다');
reset role;

-- 받은 팀(D)의 팀장이 A→D 를 거절한다
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000007","role":"authenticated"}', true);
select public.verify_run('팀 D 팀장이 A→D 거절', $sql$
update matches set status = 'REJECTED'
 where id = '00000000-0000-4000-8000-0000000000b4'
$sql$);
reset role;

select public.verify_check(
  '10-3 받은 팀 팀장의 거절: status=REJECTED + responded_at 기록',
  (select status = 'REJECTED' and responded_at is not null
     from matches where id = '00000000-0000-4000-8000-0000000000b4'),
  format('status=%s', (select status from matches
                        where id = '00000000-0000-4000-8000-0000000000b4'))
);

select public.verify_check(
  '10-4 거절은 팀 상태를 건드리지 않는다',
  (select count(*) = 2 from teams
    where id in ('00000000-0000-4000-8000-0000000000a1','00000000-0000-4000-8000-0000000000a4')
      and status = 'ACTIVE')
);


-- ------------------------------------------------------------
-- 11. 수락 — 이 프로젝트에서 가장 긴 연쇄
--
--    ⛓ 연쇄 5: matches UPDATE(ACCEPTED)
--        → (before) on_match_accepted
--            → chat_rooms INSERT
--            → teams UPDATE ×2 (MATCHED)
--                 → teams_guard_publish / teams_guard_avg_age
--            → matches UPDATE (나머지 WAITING 자동 거절)
--                 → on_match_accepted 재진입 (app.match_cascade 로 통과)
-- ------------------------------------------------------------
-- 보낸 쪽 팀장은 수락할 수 없다
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select public.verify_blocked(
  '11-1 보낸 팀 팀장은 자기 신청을 수락할 수 없다',
  $sql$update matches set status = 'ACCEPTED'
     where id = '00000000-0000-4000-8000-0000000000b1'$sql$,
  '신청을 받은 팀의 팀장만');
reset role;

-- 받은 팀(B) 팀장이 수락
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select public.verify_run('팀 B 팀장이 A→B 수락', $sql$
update matches set status = 'ACCEPTED'
 where id = '00000000-0000-4000-8000-0000000000b1'
$sql$);
reset role;

select public.verify_check(
  '11-2 매칭 성사: status=ACCEPTED + responded_at',
  (select status = 'ACCEPTED' and responded_at is not null
     from matches where id = '00000000-0000-4000-8000-0000000000b1'),
  format('status=%s', (select status from matches
                        where id = '00000000-0000-4000-8000-0000000000b1'))
);

select public.verify_check(
  '11-3 채팅방이 자동으로 만들어진다',
  (select count(*) = 1 from chat_rooms
    where match_id = '00000000-0000-4000-8000-0000000000b1')
);

select public.verify_check(
  '11-4 두 팀이 MATCHED 로 내려간다 (게시판에서 사라짐)',
  (select count(*) = 2 from teams
    where id in ('00000000-0000-4000-8000-0000000000a1','00000000-0000-4000-8000-0000000000a2')
      and status = 'MATCHED')
);

select public.verify_check(
  '11-5 같은 팀에 걸려 있던 다른 신청이 자동 거절된다 (C→B)',
  (select status = 'REJECTED' and responded_at is not null
     from matches where id = '00000000-0000-4000-8000-0000000000b2'),
  format('status=%s', (select status from matches
                        where id = '00000000-0000-4000-8000-0000000000b2'))
);

select public.verify_check(
  '11-6 수락자가 팀장이 아닌 팀의 신청도 자동 거절된다 (D→A) — 캐스케이드 통과 확인',
  (select status = 'REJECTED' and responded_at is not null
     from matches where id = '00000000-0000-4000-8000-0000000000b3'),
  format('status=%s', (select status from matches
                        where id = '00000000-0000-4000-8000-0000000000b3'))
);


-- ------------------------------------------------------------
-- 12. 수락 이후 — my_matches 뷰 / 재수락 / 매칭된 팀에 신청
-- ------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}', true);

select public.verify_check(
  '12-1 my_matches: 팀원(비팀장)도 매칭 1건과 방 id 를 본다',
  (select count(*) = 1 from my_matches
    where my_team_id = '00000000-0000-4000-8000-0000000000a1'
      and partner_team_id = '00000000-0000-4000-8000-0000000000a2'
      and room_id is not null)
);

select public.verify_check(
  '12-2 teams_select: 매칭 상대 팀을 계속 볼 수 있다 (MATCHED 인데도)',
  (select count(*) = 1 from teams where id = '00000000-0000-4000-8000-0000000000a2')
);
reset role;

-- 이미 응답한 신청은 다시 바뀌지 않는다
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000003","role":"authenticated"}', true);
select public.verify_blocked(
  '12-3 성사된 매칭을 WAITING 으로 되돌릴 수 없다',
  $sql$update matches set status = 'WAITING'
     where id = '00000000-0000-4000-8000-0000000000b1'$sql$,
  '이미 응답한 신청입니다');

select public.verify_blocked(
  '12-4 자동 거절된 신청을 뒤늦게 수락할 수 없다',
  $sql$update matches set status = 'ACCEPTED'
     where id = '00000000-0000-4000-8000-0000000000b2'$sql$,
  '이미 응답한 신청입니다');

-- 매칭이 끝난 팀을 게시판에 되돌릴 수 없다
select public.verify_blocked(
  '12-5 매칭된 팀을 다시 공개할 수 없다',
  $sql$update teams set status = 'ACTIVE'
     where id = '00000000-0000-4000-8000-0000000000a2'$sql$,
  '이미 매칭이 성사된 팀은 상태를 바꿀 수 없습니다');
reset role;

-- 매칭이 끝난 팀에는 새 신청이 들어가지 않는다
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000007","role":"authenticated"}', true);
select public.verify_blocked(
  '12-6 매칭된 팀에는 새 신청을 넣을 수 없다 (D→A 재시도)',
  $sql$insert into matches (from_team_id, to_team_id)
    values ('00000000-0000-4000-8000-0000000000a4','00000000-0000-4000-8000-0000000000a1')$sql$,
  '이미 매칭이 성사된 팀입니다');
reset role;

-- 매칭된 팀에는 초대 코드로도 못 들어간다 (capacity_guard 가 MATCHED 를 먼저 본다)
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
select public.verify_blocked(
  '12-7 매칭된 팀에는 초대 코드로도 합류할 수 없다',
  $sql$select join_team_by_code('TSTB01')$sql$,
  '이미 매칭이 성사된 팀입니다');
reset role;


-- ------------------------------------------------------------
-- 13. 약속 잡기 (set_match_plan) — 상태가 그대로인 update 는 통과해야 한다
-- ------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
select public.verify_run('팀원이 약속 잡기', $sql$
select set_match_plan('00000000-0000-4000-8000-0000000000b1',
                      current_date + 7, '19:00', '죽전역 2번 출구')
$sql$);
reset role;

select public.verify_check(
  '13-1 팀원도 약속을 잡을 수 있고 트리거가 막지 않는다',
  (select plan_date = current_date + 7 and plan_place = '죽전역 2번 출구'
     from matches where id = '00000000-0000-4000-8000-0000000000b1')
);


-- ------------------------------------------------------------
-- 14. 팀 삭제 — cascade 가 트리거와 부딪히지 않는가
--
--    ⛓ 연쇄 6: teams DELETE → team_members / matches CASCADE
--        → matches DELETE → chat_rooms CASCADE → messages CASCADE
--        → team_members DELETE → sync_fill / sync_avg_age
--          (팀이 이미 사라졌으므로 조용히 빠져나가야 한다)
-- ------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
select public.verify_run('팀 C 삭제', $sql$
delete from teams where id = '00000000-0000-4000-8000-0000000000a3'
$sql$);
reset role;

select public.verify_check(
  '14-1 팀을 지우면 팀원 행도 함께 사라진다 (트리거 오류 없이)',
  (select count(*) = 0 from team_members
    where team_id = '00000000-0000-4000-8000-0000000000a3')
);

select public.verify_check(
  '14-2 그 팀이 보낸 신청도 함께 사라진다',
  (select count(*) = 0 from matches
    where id = '00000000-0000-4000-8000-0000000000b2')
);


-- ------------------------------------------------------------
-- 15. 트리거 목록 점검 — 있어야 할 것 / 없어야 할 것
-- ------------------------------------------------------------
select public.verify_check(
  format('15-1 트리거 %s개가 제자리에 있다 (기대 11개)', x.found),
  x.found = 11,
  x.names
)
from (
  select count(*) as found, string_agg(t.tgname, ', ' order by t.tgname) as names
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  where not t.tgisinternal
    and c.relname in ('teams','team_members','matches','profiles','blocks','reports')
    and t.tgname in (
      'teams_set_invite_code','teams_set_owner_facts','teams_add_owner',
      'teams_guard_avg_age','teams_guard_publish',
      'team_members_capacity_guard','team_members_gender_guard',
      'team_members_sync_avg_age','team_members_sync_fill',
      'matches_guard_request','matches_on_accepted'
    )
) x;

select public.verify_check(
  '15-2 v1 잔재(team_members_sync_count)가 남아 있지 않다',
  not exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    where c.relname = 'team_members' and t.tgname = 'team_members_sync_count'
  ),
  '남아 있으면 filled_count 를 두 번 계산한다'
);

select public.verify_check(
  '15-3 profiles 고정 컬럼 가드가 살아 있다',
  exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    where c.relname = 'profiles' and t.tgname = 'profiles_guard_fixed_columns'
  )
);

-- 이건 트리거가 아니라 '지금 들어 있는 데이터'를 보는 항목이다.
-- 마이그레이션 010 은 앞으로 들어올 사람만 막으므로, 이미 섞여 있던
-- 팀은 손으로 정리해야 한다 (010 파일 아래쪽 조회 쿼리 참고).
select public.verify_check(
  '15-4 [데이터] 이성이 섞여 있던 기존 팀이 없다',
  x.mixed = 0,
  format('%s명', x.mixed)
)
from (
  select count(*) as mixed
  from team_members m
  join teams t    on t.id = m.team_id
  join profiles p on p.id = m.user_id
  where p.gender <> t.gender
    and t.id not between '00000000-0000-4000-8000-0000000000a1'
                     and '00000000-0000-4000-8000-0000000000a7'
) x;


-- ============================================================
-- 결과 — 아래 SELECT 와, 그 다음 예외 메시지가 같은 내용이다
-- ============================================================
select seq, case when ok then 'OK' else 'FAIL' end as 결과, step as 항목, detail as 비고
from public.verify_t_log order by seq;

do $$
declare
  v_total int;
  v_fail  int;
  v_body  text;
begin
  select count(*), count(*) filter (where not ok) into v_total, v_fail
  from public.verify_t_log;

  select string_agg(format('%s %s%s',
           case when ok then '  OK  ' else '  FAIL' end,
           step,
           case when detail is null then '' else '   → ' || detail end),
         E'\n' order by seq)
    into v_body
  from public.verify_t_log;

  raise exception E'\n\n===== 트리거 연쇄 검증 결과 =====\n%\n\n총 %건 / 실패 %건\n(검증 데이터는 이 예외와 함께 전부 롤백되었습니다)\n',
    v_body, v_total, v_fail;
end $$;

rollback;
