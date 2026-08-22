-- ============================================================
-- 마이그레이션 009 — 매칭 신청 / 수락 / 거절을 서버가 책임진다
--
-- 배경
--   지금까지 신청·수락·거절은 전부 프론트 zustand(store/useStore.ts)의
--   mock 액션이었다. 서버에는 matches 테이블과 on_match_accepted 트리거가
--   이미 있지만, 프론트를 실제로 붙이려고 흐름을 끝까지 따라가 보면
--   네 군데가 비어 있다.
--
--   [1] 신청한 팀이 상대에게 안 보인다
--       teams_select 는 '내 팀 / 매칭이 성사된(ACCEPTED) 팀 / 공개된 팀'만
--       통과시킨다. 신청을 보낸 팀이 게시판에 올라와 있지 않으면
--       (READY = 인원은 다 찼지만 비공개) 받는 쪽에서는 그 팀의 행 자체가
--       조회되지 않는다. '받은 신청' 목록이 이름 없는 빈 줄이 된다.
--       반대로 내가 보낸 신청이 거절된 뒤 상대가 다른 팀과 매칭되면
--       그 팀은 MATCHED 가 되어 다시 안 보인다. '보낸 신청' 목록도 같은 증상.
--
--   [2] 신청 자체에 아무 규칙이 없다
--       matches_insert 정책은 "내가 보내는 팀의 팀장인가"만 본다.
--       프론트 post/[id].tsx 가 검사하던 규칙(이성 팀 / 같은 인원 수)은
--       화면에만 있어서, 앱을 거치지 않으면 동성 팀에도, 인원이 다르게도,
--       심지어 아직 사람이 다 안 모인 팀으로도 신청이 들어간다.
--       (팀 안쪽에도 같은 종류의 구멍이 있다 — 초대 코드만 알면 이성도
--        팀원으로 들어온다. 그건 마이그레이션 010 이 막는다.)
--
--   [3] 이미 매칭된 팀이 또 매칭될 수 있다
--       on_match_accepted 는 수락 시점에 두 팀에 걸린 나머지 WAITING 을
--       자동 거절한다. 그런데 그 뒤에 새로 들어오는 신청은 아무도 막지
--       않는다. MATCHED 팀에 새 신청이 꽂히고 팀장이 그걸 또 수락하면
--       채팅방이 두 개 생기고 한 팀이 두 팀과 매칭된다.
--       (수락은 '받은 팀 팀장'만 가능하다는 검사는 이미 있다. 없는 건
--        '이 팀이 지금 매칭 가능한 상태인가' 쪽이다.)
--       같은 구멍이 두 개 더 있다 — 매칭된 팀을 다시 ACTIVE 로 되돌리는 길,
--       그리고 대기중 신청의 to_team_id 를 다른 팀으로 바꿔치기하는 길.
--
--   [4] 공개된 팀에서 사람이 빠져도 게시판에 그대로 남는다
--       sync_team_fill 은 status 가 ACTIVE 면 인원이 줄어도 ACTIVE 를
--       유지한다. 3명 정원 팀이 2명이 된 채로 게시판에 남고, 3:3 인 줄
--       알고 신청한 상대와 2:3 으로 만나게 된다.
--
-- 실행: Supabase Dashboard → SQL Editor 에 통째로 붙여넣고 Run
--       (전제: dku_meeting_schema_v2.sql + 마이그레이션 002~008)
--       검증: dku_meeting_verify_match_flow.sql 을 이어서 실행
-- ============================================================


-- ------------------------------------------------------------
-- 1. [1] 헬퍼 — 내 팀과 신청을 주고받은 팀인가
--
--    기존 is_matched_with_team() 은 status='ACCEPTED' 인 매칭만 본다.
--    신청은 성사되기 전(WAITING)에도, 거절된 뒤(REJECTED)에도 화면에
--    남아 있어야 하므로 status 를 가리지 않는 판정이 하나 더 필요하다.
--
--    security definer 인 이유는 기존 헬퍼들과 같다. 정책 안에서
--    team_members 를 직접 읽으면 team_members_select 가 다시 걸린다.
--
--    ⚠️ 여는 범위: "내 팀에 신청했거나, 내 팀이 신청한 팀"의 행 하나.
--       아무 팀이나 보이게 되는 게 아니라, 이미 나와 얽힌 팀만이다.
-- ------------------------------------------------------------
create or replace function is_match_counterpart_team(p_team_id uuid)
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (
    select 1
    from matches m
    join team_members tm
      on tm.team_id = case
                        when m.from_team_id = p_team_id then m.to_team_id
                        else m.from_team_id
                      end
    where p_team_id in (m.from_team_id, m.to_team_id)
      and tm.user_id = auth.uid()
  );
$$;

revoke all on function is_match_counterpart_team(uuid) from public;
grant execute on function is_match_counterpart_team(uuid) to authenticated;


-- ------------------------------------------------------------
-- 2. [1] teams_select — 마이그레이션 008 에 한 줄 추가
--
--    is_matched_with_team(id) 는 is_match_counterpart_team(id) 에
--    완전히 포함되므로(ACCEPTED ⊂ 전체) 자리를 넘긴다.
--    함수 자체는 지우지 않는다 — my_matches 뷰 등 다른 곳에서 쓴다.
-- ------------------------------------------------------------
drop policy if exists teams_select on teams;

create policy teams_select on teams for select to authenticated
using (
  is_admin()
  or owner_id = auth.uid()                    -- 008: 트리거가 돌기 전 내 팀
  or is_team_member(id)
  or is_match_counterpart_team(id)            -- ⭐ 009: 신청을 주고받은 팀
  or (status = 'ACTIVE' and not is_blocked_with_team(id))
);


-- ------------------------------------------------------------
-- 3. [1] team_members_select — 마이그레이션 007 에 한 줄 추가
--
--    상대 팀 프로필 화면(match/party/[id].tsx)이 "누가 신청했는지"를
--    팀원 카드로 보여준다. 팀 행만 열고 소속 행을 닫아두면 그 화면이
--    다시 빈다(007 과 같은 종류의 구멍).
-- ------------------------------------------------------------
drop policy if exists team_members_select on team_members;

create policy team_members_select on team_members for select to authenticated
using (
  is_team_member(team_id)
  or is_matched_with_team(team_id)
  or is_listed_team(team_id)                  -- 007: 게시판에 공개된 팀
  or is_match_counterpart_team(team_id)       -- ⭐ 009: 신청을 주고받은 팀
  or is_admin()
);


-- ------------------------------------------------------------
-- 4. [2] 신청 유효성 검사 (before insert on matches)
--
--    프론트 post/[id].tsx 의 검사를 그대로 서버로 옮긴 것이다.
--    문구는 화면에 그대로 뜨므로 사람이 읽을 한국어로 쓴다
--    (api/client.ts 의 describeMatchError 가 이 문구들을 통과시킨다).
--
--    같은 팀에 대기중 신청을 두 번 보내는 것은 스키마의
--    matches_no_duplicate_waiting 부분 유니크 인덱스가 막는다(23505).
--    여기서 또 세면 검사만 두 벌이 되고 경합에는 인덱스가 더 정확하다.
-- ------------------------------------------------------------
create or replace function assert_match_request_valid()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_from teams%rowtype;
  v_to   teams%rowtype;
begin
  select * into v_from from teams where id = new.from_team_id;
  if not found then
    raise exception '신청할 팀을 찾을 수 없습니다' using errcode = 'check_violation';
  end if;

  select * into v_to from teams where id = new.to_team_id;
  if not found then
    raise exception '상대 팀을 찾을 수 없습니다' using errcode = 'check_violation';
  end if;

  -- 이미 매칭이 끝난 팀은 신청도 못 하고 받지도 못한다
  if v_from.status = 'MATCHED' or v_to.status = 'MATCHED' then
    raise exception '이미 매칭이 성사된 팀입니다' using errcode = 'check_violation';
  end if;

  -- 게시판에 올라와 있는 팀에만 신청할 수 있다.
  -- (teams_select 가 이미 남의 비공개 팀을 가리지만, 초대 코드로 알아낸
  --  팀 id 로 직접 찔러 넣는 길이 남아 있다)
  if v_to.status <> 'ACTIVE' then
    raise exception '게시판에 공개된 팀에만 신청할 수 있습니다' using errcode = 'check_violation';
  end if;

  -- 우리 팀이 다 모이지 않았으면 신청할 수 없다.
  -- 상대는 '다 모인 팀'이라고 믿고 수락하는 것이라 대칭이 맞아야 한다.
  if v_from.filled_count < v_from.capacity then
    raise exception '우리 팀 인원이 다 모여야 신청할 수 있습니다' using errcode = 'check_violation';
  end if;

  -- 과팅이므로 이성 팀에만
  if v_from.gender = v_to.gender then
    raise exception '이성 팀에만 신청할 수 있습니다' using errcode = 'check_violation';
  end if;

  -- 3:3 은 3:3 끼리. 인원 수가 다르면 만남 자체가 성립하지 않는다
  if v_from.capacity <> v_to.capacity then
    raise exception '인원 수가 같은 팀에만 신청할 수 있습니다' using errcode = 'check_violation';
  end if;

  return new;
end; $$;

drop trigger if exists matches_guard_request on matches;
create trigger matches_guard_request
before insert on matches
for each row execute function assert_match_request_valid();


-- ------------------------------------------------------------
-- 5. [3] 수락 / 거절 뒷처리 — v2 스키마의 on_match_accepted 교체
--
--    v2 에서 하던 일(응답 시각·채팅방·MATCHED 전이·나머지 자동 거절)은
--    그대로 두고, 앞뒤로 세 가지를 더한다.
--
--    (a) 응답은 한 번뿐이다
--        이미 ACCEPTED/REJECTED 인 신청의 status 를 다시 바꿀 수 없다.
--        matches_update 정책은 양쪽 팀장을 모두 통과시키므로, 이게 없으면
--        성사된 매칭을 보낸 쪽이 WAITING 으로 되돌려 두 팀 상태와
--        채팅방만 남는 유령 상태를 만들 수 있다.
--
--    (b) 거절도 권한을 본다
--        받은 팀 팀장 = 거절, 보낸 팀 팀장 = 신청 취소. 둘 다 허용하되
--        제3자(정책은 통과하지 못하지만 트리거는 최종 방어선이다)는 막는다.
--
--    (c) 수락 시점에 두 팀 상태를 다시 확인한다
--        신청이 들어온 뒤 수락까지 사이에 상대가 다른 팀과 매칭됐거나
--        팀원이 빠졌을 수 있다. 신청 시점 검사(4번)만으로는 부족하다.
--        두 팀 행을 id 순서로 잠가 동시 수락 경합도 함께 막는다.
--        (id 순서로 잠그지 않으면 A→B 와 B→A 를 양쪽이 동시에 수락할 때
--         교착이 난다.)
--
--    ⚠️ app.match_cascade 표식
--       아래 자동 거절은 '내가 팀장이 아닌 팀'의 신청까지 REJECTED 로
--       바꾼다(상대 팀이 다른 데서 받아 둔 신청들). 그 update 도 이
--       트리거를 다시 밟으므로, (b)의 권한 검사에 그대로 걸려 수락 전체가
--       실패한다. 마이그레이션 006 의 app.sync_avg_age 와 같은 방식으로
--       "이 update 는 트리거가 한 것"이라는 트랜잭션 한정 표식을 세운다.
--
--    ⚠️ 남는 경합 하나
--       겹치는 팀에 걸린 두 수락이 정확히 동시에 들어오면
--       (한쪽은 teams 를 잡고 상대 matches 를 기다리고, 다른 쪽은 그 반대)
--       Postgres 가 교착을 감지해 한쪽을 40P01 로 끊는다. 어차피 한쪽은
--       '이미 매칭이 성사된 팀입니다'로 실패해야 하는 상황이라 결과는 같고,
--       앱은 이 오류를 "잠시 후 다시 시도해주세요"로 바꿔 보여준다
--       (api/client.ts describeMatchError).
-- ------------------------------------------------------------
create or replace function on_match_accepted()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_from teams%rowtype;
  v_to   teams%rowtype;
begin
  -- 신청 대상은 못 바꾼다.
  --   matches_update 정책은 '양쪽 팀장'을 통과시키고 USING 이 WITH CHECK 로도
  --   쓰이므로, 보낸 팀 팀장이 to_team_id 만 다른 팀으로 바꿔치기하면
  --   BEFORE INSERT 가드(4번)를 통째로 건너뛴 신청이 만들어진다.
  if new.from_team_id is distinct from old.from_team_id
     or new.to_team_id is distinct from old.to_team_id then
    raise exception '신청 대상은 바꿀 수 없습니다' using errcode = 'check_violation';
  end if;

  -- 약속(plan_*) 수정처럼 상태가 그대로인 update 는 지나간다
  if new.status is not distinct from old.status then
    return new;
  end if;

  -- 자동 거절 캐스케이드가 스스로를 다시 밟는 경우
  if coalesce(current_setting('app.match_cascade', true), 'off') = 'on' then
    new.responded_at = now();
    return new;
  end if;

  -- (a) 한 번 응답한 신청은 다시 바뀌지 않는다
  if old.status <> 'WAITING' and not is_admin() then
    raise exception '이미 응답한 신청입니다' using errcode = 'check_violation';
  end if;

  if new.status = 'ACCEPTED' then
    -- 수락 권한은 '받는 팀'의 팀장에게만 있다
    -- (matches_update 정책만으로는 방향을 구분할 수 없다)
    if not (is_team_owner(new.to_team_id) or is_admin()) then
      raise exception '신청을 받은 팀의 팀장만 수락할 수 있습니다' using errcode = 'check_violation';
    end if;

    -- (c) 두 팀을 id 순서로 잠근 뒤 지금 상태를 다시 본다
    perform 1 from teams
     where id in (new.from_team_id, new.to_team_id)
     order by id
     for update;

    select * into v_from from teams where id = new.from_team_id;
    select * into v_to   from teams where id = new.to_team_id;

    if v_from.status = 'MATCHED' or v_to.status = 'MATCHED' then
      raise exception '이미 매칭이 성사된 팀입니다' using errcode = 'check_violation';
    end if;

    if v_from.filled_count < v_from.capacity
       or v_to.filled_count < v_to.capacity then
      raise exception '양쪽 팀원이 다 모여야 매칭할 수 있습니다' using errcode = 'check_violation';
    end if;

    new.responded_at = now();

    insert into chat_rooms (match_id) values (new.id)
    on conflict (match_id) do nothing;

    update teams set status = 'MATCHED'
    where id in (new.from_team_id, new.to_team_id);

    -- 두 팀에 걸려 있던 나머지 대기중 신청을 자동 거절
    perform set_config('app.match_cascade', 'on', true);

    update matches
    set status = 'REJECTED', responded_at = now()
    where status = 'WAITING'
      and id <> new.id
      and (from_team_id in (new.from_team_id, new.to_team_id)
        or to_team_id   in (new.from_team_id, new.to_team_id));

    perform set_config('app.match_cascade', 'off', true);

  elsif new.status = 'REJECTED' then
    -- (b) 받은 팀 팀장 = 거절 / 보낸 팀 팀장 = 신청 취소
    if not (is_team_owner(new.to_team_id)
            or is_team_owner(new.from_team_id)
            or is_admin()) then
      raise exception '이 신청을 처리할 권한이 없습니다' using errcode = 'check_violation';
    end if;

    new.responded_at = now();

  else
    -- WAITING 으로 되돌리는 경로는 없다. (a)에서 이미 막히지만 명시해 둔다.
    raise exception '신청 상태를 되돌릴 수 없습니다' using errcode = 'check_violation';
  end if;

  return new;
end; $$;

-- 트리거 자체는 v2 에서 만든 것을 그대로 쓴다(이름·시점 동일).
-- 혹시 지워졌거나 이름이 다른 환경을 위해 다시 세운다.
drop trigger if exists matches_on_accepted on matches;
create trigger matches_on_accepted
before update on matches
for each row execute function on_match_accepted();


-- ------------------------------------------------------------
-- 6. [4] 팀원이 빠지면 게시판에서 내려간다 — sync_team_fill 교체
--
--    ⚠️ 동작이 바뀌는 부분이다.
--       이전: 공개중(ACTIVE)인 팀은 인원이 줄어도 계속 공개.
--       이후: 정원이 깨지면 RECRUITING 으로 내려가고 게시판에서 사라진다.
--             다시 채워지면 READY 가 되고, 공개는 팀장이 다시 누른다.
--
--    나머지는 v2 와 같다. MATCHED 팀의 상태는 인원 변동으로 바뀌지 않는다
--    (매칭이 끝난 팀에서 한 명 빠졌다고 채팅방이 사라지면 안 된다).
--
--    이 규칙이 없으면 5-(c)의 '양쪽이 다 모였는가' 검사에 걸려
--    수락만 조용히 실패한다. 원인은 게시판에 있으니 게시판에서 고친다.
-- ------------------------------------------------------------
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
        when v_status = 'MATCHED'              then v_status
        when v_count >= v_cap and v_status = 'ACTIVE' then 'ACTIVE'::team_status
        when v_count >= v_cap                  then 'READY'::team_status
        -- ⭐ 009: 정원이 깨지면 공개중이던 팀도 모집중으로 내려간다
        else                                        'RECRUITING'::team_status
      end
  where id = v_team_id;

  return coalesce(new, old);
end; $$;

-- 트리거는 v2 에서 만든 것과 이름·시점이 같다. 다만 "이미 있겠지"에
-- 기대면, 어쩌다 빠져 있는 환경에서 함수만 바뀌고 규칙은 조용히 사라진다.
-- 다시 세워 둔다(같은 정의라 여러 번 실행해도 결과가 같다).
drop trigger if exists team_members_sync_fill on team_members;
create trigger team_members_sync_fill
after insert or delete on team_members
for each row execute function sync_team_fill();


-- ------------------------------------------------------------
-- 7. [3-보강] 매칭된 팀은 게시판으로 되돌아갈 수 없다
--
--    teams_guard_publish 는 '정원이 찼는가'만 본다. 그런데 매칭이 끝난 팀은
--    정원이 차 있으므로, 팀장이 상태를 다시 ACTIVE 로 바꾸는 요청이 그대로
--    통과한다. 그러면 채팅방은 그대로 둔 채 팀만 게시판에 되돌아오고,
--    status 가 MATCHED 가 아니게 되어 4·5번의 '이미 매칭된 팀' 검사까지
--    빠져나간다 — 한 팀이 두 팀과 매칭될 수 있는 마지막 구멍이다.
--
--    (앱에서도 my_team.tsx 의 공개 버튼이 매칭된 팀에 그대로 떴다.
--     화면은 화면대로 고쳤지만, 규칙은 여기에 있어야 한다.)
-- ------------------------------------------------------------
create or replace function assert_team_full_before_publish()
returns trigger language plpgsql as $$
begin
  -- 매칭이 끝난 팀의 상태는 더 이상 사람이 바꾸지 않는다.
  -- (트리거가 하는 MATCHED → MATCHED 는 status 가 그대로라 걸리지 않는다)
  if old.status = 'MATCHED' and new.status <> 'MATCHED' and not is_admin() then
    raise exception '이미 매칭이 성사된 팀은 상태를 바꿀 수 없습니다'
      using errcode = 'check_violation';
  end if;

  -- 'ACTIVE 로 바뀌는 순간'만 본다. 이미 공개된 팀에서 팀원이 나가
  -- sync_team_fill() 이 filled_count 를 낮추는 경우까지 막으면
  -- 팀 나가기가 통째로 실패한다.
  if new.status = 'ACTIVE'
     and old.status is distinct from 'ACTIVE'
     and new.filled_count < new.capacity then
    raise exception '팀원이 다 모여야 게시판에 공개할 수 있습니다'
      using errcode = 'check_violation';
  end if;

  return new;
end; $$;

-- 마이그레이션 005 의 트리거와 같은 정의다. 위와 같은 이유로 다시 세운다.
drop trigger if exists teams_guard_publish on teams;
create trigger teams_guard_publish
before update on teams
for each row execute function assert_team_full_before_publish();


-- ------------------------------------------------------------
-- 8. 확인
-- ------------------------------------------------------------
-- 트리거가 제자리에 있는가
-- select c.relname as 테이블, t.tgname as 트리거, p.proname as 함수,
--        case when t.tgtype::int & 2 = 2 then 'BEFORE' else 'AFTER' end as 시점
-- from pg_trigger t
-- join pg_class c on c.oid = t.tgrelid
-- join pg_proc  p on p.oid = t.tgfoid
-- where not t.tgisinternal
--   and c.relname in ('teams', 'team_members', 'matches', 'profiles')
-- order by c.relname, t.tgname;
--
-- 정책이 새 헬퍼를 보고 있는가
-- select tablename, policyname, qual
-- from pg_policies
-- where tablename in ('teams', 'team_members') and cmd = 'SELECT';
