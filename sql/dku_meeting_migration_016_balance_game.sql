-- ============================================================
-- 마이그레이션 016 — 오늘의 밸런스 게임
--
-- 홈 화면에 매일 하나씩 뜨는 양자택일 질문과 그 투표.
-- 초기에는 공개된 팀이 몇 개 없어 홈이 거의 빈 채로 열리는데, 매일 바뀌는
-- 질문 하나가 "내려볼 것이 있는 화면"을 만든다.
--
-- 질문에 날짜를 박지 않는다
--   balance_questions 에는 순번(id)만 있고 "며칠에 보여줄 질문"은 없다.
--   날짜를 박으면 그 날짜가 지나는 순간 화면이 비고, 누군가 주기적으로
--   질문을 채워 넣어야 한다. 대신 오늘 날짜로 순번을 골라(balance_today_id)
--   목록을 돌려 쓴다 — 질문이 24개면 24일마다 한 바퀴 돌고, 아무도 아무것도
--   안 해도 화면이 비지 않는다. 한 바퀴 돌아 다시 나온 질문에는 이전 표가
--   그대로 쌓여 있고, 그때 이미 고른 사람은 결과부터 보게 된다.
--
-- 표는 아무도 못 읽는다 — 집계만 나간다
--   balance_votes 는 select 를 열지 않는다. 열면 "누가 무엇을 골랐는지"가
--   그대로 조회된다. 앱에는 security definer 함수가 계산한 개수 두 개와
--   "내가 고른 것" 만 나간다.
--
-- 한 번 고르면 못 바꾼다
--   결과를 본 뒤 이긴 쪽으로 갈아타는 걸 막는다. 바꾸기를 열어 주려면
--   vote_balance_game 의 on conflict 를 do update 로 바꾸면 된다.
--
-- 실행: Supabase Dashboard → SQL Editor 에 통째로 붙여넣고 Run
--       (전제: 마이그레이션 001 — profiles)
--       여러 번 돌려도 안전하다. 질문 문구는 다시 돌릴 때마다 갱신된다.
-- ============================================================


-- ------------------------------------------------------------
-- 1. 질문 목록
--
--    id 를 직접 박는다. serial 로 두면 이 파일을 다시 돌릴 때마다 같은
--    질문이 새 id 로 또 들어가고, 그러면 쌓여 있던 표와 끊어진다.
-- ------------------------------------------------------------
create table if not exists balance_questions (
  id       smallint primary key,
  question text not null,
  option_a text not null,
  option_b text not null
);

comment on table balance_questions is
  '홈 밸런스 게임 질문 풀. 오늘 질문은 날짜로 고른다 (마이그레이션 016)';

alter table balance_questions enable row level security;

-- 앱은 RPC 로만 읽는다. 표 없이 질문만 통째로 긁어 갈 이유가 없다.
drop policy if exists balance_questions_read_denied on balance_questions;
create policy balance_questions_read_denied on balance_questions for select to authenticated
using (false);


-- ------------------------------------------------------------
-- 2. 표
--
--    (질문, 사람)이 기본키라 한 사람이 같은 질문에 두 번 넣을 수 없다.
--    개수 세기가 유일한 용도라 인덱스도 이 기본키면 충분하다.
-- ------------------------------------------------------------
create table if not exists balance_votes (
  question_id smallint    not null references balance_questions(id) on delete cascade,
  user_id     uuid        not null references profiles(id) on delete cascade,
  choice      char(1)     not null check (choice in ('A', 'B')),
  created_at  timestamptz not null default now(),

  primary key (question_id, user_id)
);

comment on table balance_votes is
  '밸런스 게임 투표. 집계는 RPC 로만 나간다 — 누가 무엇을 골랐는지는 안 열린다 (마이그레이션 016)';

alter table balance_votes enable row level security;

drop policy if exists balance_votes_select_denied on balance_votes;
drop policy if exists balance_votes_insert_denied on balance_votes;
drop policy if exists balance_votes_update_denied on balance_votes;
drop policy if exists balance_votes_delete_denied on balance_votes;

-- 넷 다 닫는다. 읽기도 쓰기도 아래 함수(security definer)를 거친다.
create policy balance_votes_select_denied on balance_votes for select to authenticated
using (false);

create policy balance_votes_insert_denied on balance_votes for insert to authenticated
with check (false);

create policy balance_votes_update_denied on balance_votes for update to authenticated
using (false);

create policy balance_votes_delete_denied on balance_votes for delete to authenticated
using (false);


-- ------------------------------------------------------------
-- 3. 오늘의 질문 순번
--
--    서버는 UTC 로 돈다. 그대로 쓰면 한국에서 아침 9시에 질문이 바뀐다.
--    자정에 바뀌어야 하므로 서울 시각의 날짜로 센다.
-- ------------------------------------------------------------
create or replace function balance_today_id()
returns smallint language sql stable
set search_path = public as $$
  with pool as (select count(*)::int as n from balance_questions)
  select id from balance_questions
  order by id
  offset (
    select case
      when n = 0 then 0
      -- 나머지에 n 을 더해 한 번 더 나눈다. 기준일 이전 날짜에서 음수
      -- 나머지가 나오면 offset 이 오류가 난다.
      else ((timezone('Asia/Seoul', now())::date - date '2024-01-01') % n + n) % n
    end
    from pool
  )
  limit 1;
$$;


-- ------------------------------------------------------------
-- 4. 돌려줄 한 줄의 모양
--
--    두 함수가 같은 모양을 돌려준다. 이걸 `returns table (...)` 로 각자
--    적으면 plpgsql 쪽에서 그 이름들이 전부 함수 변수가 되고, 그 순간
--    balance_votes 의 같은 이름 컬럼과 부딪친다 —
--      insert ... on conflict (question_id, user_id)
--    의 question_id 가 "변수인지 컬럼인지" 모호해져 42702 로 죽는다.
--    (plpgsql 본문은 만들 때가 아니라 처음 부를 때 이름을 푼다. 그래서
--     마이그레이션은 멀쩡히 돌고 앱에서 투표할 때 터진다)
--
--    타입으로 한 번만 정의하고 `returns setof` 로 받으면 변수가 아예
--    생기지 않아 그 문제가 사라진다. 모양이 한 곳에만 적히는 건 덤이다.
-- ------------------------------------------------------------
-- 두 함수를 먼저 지운다.
--
-- create or replace 는 "반환 타입이 그대로"일 때만 통한다. 이 파일의 앞
-- 판본은 두 함수를 returns table (...) 로 만들었으므로, 그때 한 번 돌린
-- 데이터베이스에서는 replace 가 반환 타입을 바꾸려다 42P13 으로 막힌다.
--   ERROR: cannot change return type of existing function
--
-- 아래 drop type ... cascade 로는 못 잡는다. 그 판본에는 이 타입이 아예
-- 없어서 cascade 가 지울 것을 못 찾기 때문이다. 함수를 직접 지워야 한다.
-- (표가 든 balance_votes 는 건드리지 않으므로 쌓인 표는 그대로다)
drop function if exists vote_balance_game(smallint, text);
drop function if exists balance_game_today();

-- 이 타입으로 이미 한 번 만들어진 데이터베이스를 위해 타입도 지운다.
-- cascade 가 위 함수들을 함께 지우지만 바로 다시 만들므로 괜찮다.
drop type if exists balance_game_result cascade;

create type balance_game_result as (
  question_id smallint,
  question    text,
  option_a    text,
  option_b    text,
  votes_a     integer,
  votes_b     integer,
  my_choice   text
);


-- ------------------------------------------------------------
-- 5. 오늘의 질문 + 집계 + 내 선택
--
--    한 번의 왕복으로 화면이 필요한 걸 다 준다. 아직 아무도 안 골랐으면
--    개수는 0 이고 my_choice 는 null 이다.
-- ------------------------------------------------------------
create or replace function balance_game_today()
returns setof balance_game_result
language sql security definer stable
set search_path = public as $$
  select
    q.id,
    q.question,
    q.option_a,
    q.option_b,
    (count(*) filter (where v.choice = 'A'))::integer,
    (count(*) filter (where v.choice = 'B'))::integer,
    -- 한 사람당 한 줄이라 max 는 "내 한 줄"을 꺼내는 수단일 뿐이다.
    -- char(1) 그대로 모으지 않고 text 로 바꿔서 모은다 — 돌려줄 타입이 text 다.
    max(v.choice::text) filter (where v.user_id = auth.uid())
  from balance_questions q
  left join balance_votes v on v.question_id = q.id
  where q.id = balance_today_id()
  group by q.id, q.question, q.option_a, q.option_b;
$$;


-- ------------------------------------------------------------
-- 6. 투표
--
--    넣은 뒤 갱신된 집계를 그대로 돌려준다. 앱이 투표하고 결과를 보려고
--    두 번 왕복하지 않게 한다.
-- ------------------------------------------------------------
create or replace function vote_balance_game(
  p_question_id smallint,
  p_choice      text
)
returns setof balance_game_result
language plpgsql security definer
set search_path = public as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception '로그인이 필요합니다' using errcode = 'insufficient_privilege';
  end if;

  if p_choice is null or p_choice not in ('A', 'B') then
    raise exception '선택지가 올바르지 않습니다' using errcode = 'check_violation';
  end if;

  -- 어제 질문에 오늘 표를 넣는 것을 막는다. 화면이 낡은 질문을 들고 있다가
  -- 자정을 넘겨 누르는 경우가 실제로 생긴다.
  if p_question_id is distinct from balance_today_id() then
    raise exception '오늘의 질문이 아닙니다' using errcode = 'check_violation';
  end if;

  -- 이미 고른 사람은 그대로 둔다. 결과를 보고 이긴 쪽으로 갈아타지 못한다.
  --
  -- 충돌 대상을 컬럼 이름이 아니라 제약 이름으로 적는다. plpgsql 은
  -- on conflict (...) 안의 이름을 변수로도 해석해 보는데, 이 파일이 커지며
  -- 같은 이름의 변수가 하나라도 생기면 그 순간 42702 로 죽는다.
  -- 제약 이름은 변수와 겹칠 수 없어 그 여지가 아예 없다.
  insert into balance_votes (question_id, user_id, choice)
  values (p_question_id, v_user, p_choice)
  on conflict on constraint balance_votes_pkey do nothing;

  return query select * from balance_game_today();
end; $$;


-- balance_today_id 는 위 두 함수가 쓰는 내부 함수다. 앱이 부를 일이 없다.
revoke all on function balance_today_id() from public;
revoke all on function balance_today_id() from anon;
revoke all on function balance_today_id() from authenticated;

revoke all on function balance_game_today() from public;
grant execute on function balance_game_today() to authenticated;

revoke all on function vote_balance_game(smallint, text) from public;
grant execute on function vote_balance_game(smallint, text) to authenticated;


-- ------------------------------------------------------------
-- 7. 질문 채우기
--
--    문구를 고치고 이 파일을 다시 돌리면 갱신된다(id 는 그대로라 표도 그대로).
--    질문을 추가할 때는 뒤에 이어 붙이기만 하면 된다 — 목록이 길어지면
--    한 바퀴 도는 주기가 그만큼 늘어난다.
-- ------------------------------------------------------------
insert into balance_questions (id, question, option_a, option_b) values
  ( 1, '친구가 사귀었던 사람과 연애하기',            '가능하다',     '불가능하다'),
  ( 2, '연인이 내 휴대폰을 보여 달라고 한다면',      '이해한다',     '이해 못 한다'),
  ( 3, '사귀기 전에 이성 친구와 단둘이 술자리',      '가능하다',     '불가능하다'),
  ( 4, '헤어진 뒤에도 친구로 지내기',                '가능하다',     '불가능하다'),
  ( 5, '연인이 이성 친구와 단둘이 연락하는 것',      '이해한다',     '이해 못 한다'),
  ( 6, '장거리 연애',                                '가능하다',     '불가능하다'),
  ( 7, '연인이 우리 사진을 SNS에 안 올리는 것',      '이해한다',     '이해 못 한다'),
  ( 8, '첫 데이트 비용은 각자 내기',                 '당연하다',     '아쉽다'),
  ( 9, '만난 지 한 달 안에 고백하기',                '적당하다',     '너무 이르다'),
  (10, '썸 타는 동안 다른 사람과도 썸 타기',         '가능하다',     '불가능하다'),
  (11, '연인과 휴대폰 비밀번호 공유하기',            '가능하다',     '불가능하다'),
  (12, '시험 기간에 연락이 확 줄어드는 연인',        '이해한다',     '이해 못 한다'),
  (13, '나이 차이 다섯 살 이상 연애',                '가능하다',     '불가능하다'),
  (14, '싸운 날은 자기 전에 꼭 풀어야 한다',         '그래야 한다',  '시간이 필요하다'),
  (15, '기념일을 안 챙기는 연인',                    '이해한다',     '이해 못 한다'),
  (16, '소개팅 전에 상대 SNS 찾아보기',              '당연히 한다',  '안 한다'),
  (17, '캠퍼스 커플(CC)',                            '추천한다',     '말리고 싶다'),
  (18, '연인이 내 친구들과 만나기를 꺼리는 것',      '이해한다',     '이해 못 한다'),
  (19, '연애 중에 옛 연애 이야기 묻기',              '괜찮다',       '불편하다'),
  (20, '과팅에서 첫인상만 보고 정하기',              '가능하다',     '불가능하다'),
  (21, '연인의 취미에 큰돈이 들어가는 것',           '이해한다',     '이해 못 한다'),
  (22, '만난 다음 날 바로 연락하기',                 '좋다',         '부담된다'),
  (23, '커플 통장 만들기',                           '필요하다',     '필요 없다'),
  (24, '연인이 내 연락에 하루 뒤에 답하는 것',       '이해한다',     '이해 못 한다')
on conflict (id) do update set
  question = excluded.question,
  option_a = excluded.option_a,
  option_b = excluded.option_b;


-- ------------------------------------------------------------
-- 확인 (선택) — SQL Editor 에서 바로 돌려볼 수 있다
--
--   select * from balance_game_today();
--     → 오늘의 질문이 한 줄. 아직 아무도 안 골랐으면 votes 는 0, 0 이고
--       my_choice 는 null 이다.
--
--   vote_balance_game 은 auth.uid() 가 필요하다. SQL Editor 에는 로그인한
--   사용자가 없으므로 '로그인이 필요합니다' 가 나오는 게 정상이다.
--   투표는 앱에서 눌러 확인한다.
-- ------------------------------------------------------------
