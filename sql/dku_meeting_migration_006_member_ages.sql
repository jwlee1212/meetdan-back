-- ============================================================
-- 마이그레이션 006 — 평균 나이를 서버가 계산한다 + 태그 자유 입력 보호
--
-- 문제 1. teams.avg_age 를 사람이 손으로 적는다
--   write.tsx 가 "평균 나이는?" 입력칸을 두고 그 값을 그대로 teams.avg_age
--   에 넣었다. 22살 셋이 모인 팀이 "평균 19세"라고 적어도 아무도 못 막는다.
--   게시판 카드·상세 화면이 전부 이 값을 그대로 보여주므로, 나이는 사실상
--   자기소개 문구와 다를 바 없는 상태였다.
--
--   dept / gender 를 생성자 프로필에서 복사한 마이그레이션 005 와 같은 결론:
--   사람에게서 나오는 사실은 프로필 한 곳에서만 받고, 팀 값은 서버가 만든다.
--
--   그런데 profiles 에는 나이가 없었다. 그래서 여기서
--     · profiles.birth_year 를 추가하고 (가입 3단계에서 받는다)
--     · team_members 가 바뀔 때마다 teams.avg_age 를 다시 계산한다.
--
--   나이가 아니라 '출생연도'를 받는 이유: 나이를 그대로 저장하면 해가
--   바뀌어도 값이 안 늙는다. 출생연도는 한 번 받으면 영원히 맞다.
--
-- 문제 2. 태그가 자유 입력으로 바뀌면서 상한이 사라진다
--   지금까지 write.tsx 가 고정 목록에서 최대 3개만 고르게 해서 teams.tags
--   에는 짧은 값 3개까지만 들어왔다. 입력칸으로 바꾸면 그 보장이 화면에만
--   남는다. 길이/개수 제한을 스키마로 내린다.
--
-- 실행: Supabase Dashboard → SQL Editor 에 통째로 붙여넣고 Run
-- ============================================================


-- ------------------------------------------------------------
-- 1. profiles.birth_year — 가입 시 받는 출생연도
--
--    check 에 now() 를 쓸 수 없어서(비-immutable 함수는 제약에 못 들어간다)
--    상수 범위로 둔다. 실제 입력 검증은 가입 화면과 아래 korean_age() 를
--    쓰는 쪽에서 한다.
--
--    기존 계정은 값이 없으므로 nullable 이다. 4번의 가드가 'null → 값'
--    한 번만 허용하므로, 이미 가입한 사람도 나중에 한 번은 채울 수 있다.
-- ------------------------------------------------------------
alter table profiles add column if not exists birth_year int
  check (birth_year is null or birth_year between 1950 and 2020);

comment on column profiles.birth_year is
  '가입 시 확정. teams.avg_age 계산의 유일한 입력값이다.';


-- ------------------------------------------------------------
-- 2. 한국 나이 계산
--    화면이 "평균 23세"처럼 세는나이로 보여주고 있어서 그대로 맞춘다.
--    now() 를 쓰므로 immutable 이 아니라 stable 이다 → 인덱스/제약에는 못 쓴다.
-- ------------------------------------------------------------
create or replace function korean_age(p_birth_year int)
returns int language sql stable as $$
  select extract(year from (now() at time zone 'Asia/Seoul'))::int
         - p_birth_year + 1;
$$;


-- ------------------------------------------------------------
-- 3. teams.avg_age 를 계산 컬럼으로 바꾼다
--
--    · not null 해제 — 팀원 전원이 출생연도를 아직 안 채운 옛 계정이면
--      평균을 낼 수 없다. 그때는 null 이고 화면이 '—' 로 그린다.
--    · 18~40 범위 해제 — 이제 사람이 적는 값이 아니라 계산 결과다.
--      계산 결과가 범위를 벗어났다고 팀 합류가 통째로 실패하면 안 된다.
-- ------------------------------------------------------------
alter table teams alter column avg_age drop not null;

do $$
declare
  r record;
begin
  for r in
    select con.conname
    from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    where c.relname = 'teams'
      and con.contype = 'c'
      and pg_get_constraintdef(con.oid) ilike '%avg_age%'
  loop
    execute format('alter table teams drop constraint %I', r.conname);
    raise notice 'avg_age 제약 제거: %', r.conname;
  end loop;
end $$;

alter table teams add constraint teams_avg_age_sane
  check (avg_age is null or avg_age between 15 and 99);

comment on column teams.avg_age is
  '팀원 출생연도의 평균(세는나이, 반올림). 서버가 계산한다. 클라이언트 값은 무시된다.';


-- ------------------------------------------------------------
-- 4. birth_year 는 한 번만 채울 수 있다
--
--    마이그레이션 003 의 고정 컬럼 가드에 birth_year 를 얹는다.
--    다만 'null → 값' 은 통과시킨다. 006 이전에 가입한 계정이
--    프로필에서 한 번 채워 넣을 통로가 필요하기 때문이다.
--    한 번 채워진 뒤에는 다른 고정 컬럼과 똑같이 잠긴다.
-- ------------------------------------------------------------
create or replace function guard_profile_update()
returns trigger language plpgsql as $$
begin
  if is_admin() then
    return new;
  end if;

  if new.login_id        is distinct from old.login_id
  or new.name             is distinct from old.name
  or new.email            is distinct from old.email
  or new.gender           is distinct from old.gender
  or new.campus           is distinct from old.campus
  or new.dept             is distinct from old.dept
  or new.email_verified_at is distinct from old.email_verified_at
  or new.status           is distinct from old.status
  or new.strike_count     is distinct from old.strike_count
  or new.suspended_until  is distinct from old.suspended_until
  or new.deleted_at       is distinct from old.deleted_at
  then
    raise exception '가입 정보 및 운영 컬럼은 본인이 직접 수정할 수 없어요.'
      using errcode = '42501';
  end if;

  if old.birth_year is not null
     and new.birth_year is distinct from old.birth_year then
    raise exception '출생연도는 한 번 등록하면 바꿀 수 없어요.'
      using errcode = '42501';
  end if;

  return new;
end;
$$;


-- ------------------------------------------------------------
-- 5. 가입 트리거가 birth_year 도 채운다
--    마이그레이션 002 의 handle_new_user 에 한 줄 얹는 것뿐이다.
--    signUp({ options: { data: { birth_year } } }) 로 넘어온 값을 읽는다.
--    (앱을 거치지 않은 계정은 값이 없어 null 로 들어간다 → 4번이 나중에
--     한 번 채우는 걸 허용한다.)
-- ------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  if m ->> 'login_id' is null then
    raise notice 'raw_user_meta_data 에 login_id 가 없어 profiles 생성을 건너뜁니다 (user %)', new.id;
    return new;
  end if;

  insert into public.profiles (
    id, login_id, name, email, gender, campus, dept, birth_year, email_verified_at
  )
  values (
    new.id,
    m ->> 'login_id',
    m ->> 'name',
    new.email,
    (m ->> 'gender')::gender_t,
    (m ->> 'campus')::campus_t,
    m ->> 'dept',
    nullif(m ->> 'birth_year', '')::int,
    -- 마이그레이션 002 참고: 앱이 verify-email 을 끝낸 뒤에만 가입을 요청한다는
    -- 신뢰에 기대고 있다.
    now()
  );

  return new;
end;
$$;


-- ------------------------------------------------------------
-- 6. 팀 생성 시 평균 나이 = 팀장 나이
--
--    마이그레이션 005 의 set_team_owner_facts 를 확장한다. 팀이 막
--    만들어진 시점에는 팀원이 팀장 하나뿐이라 팀장 나이가 곧 평균이다.
--    (teams_add_owner 가 team_members 를 채우는 건 insert 가 끝난 뒤라
--     여기서 미리 넣어두지 않으면 목록 첫 조회에 null 이 보인다.)
-- ------------------------------------------------------------
create or replace function set_team_owner_facts()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_dept       text;
  v_gender     gender_t;
  v_birth_year int;
begin
  select dept, gender, birth_year
  into v_dept, v_gender, v_birth_year
  from profiles where id = new.owner_id;

  if not found then
    raise exception '프로필이 없어 팀을 만들 수 없습니다';
  end if;

  new.dept    := v_dept;
  new.gender  := v_gender;
  -- 클라이언트가 avg_age 를 보내더라도 여기서 덮인다.
  new.avg_age := case
                   when v_birth_year is null then null
                   else korean_age(v_birth_year)
                 end;
  return new;
end; $$;

drop trigger if exists teams_set_owner_facts on teams;
create trigger teams_set_owner_facts
before insert on teams
for each row execute function set_team_owner_facts();


-- ------------------------------------------------------------
-- 7. 팀원이 들어오고 나갈 때마다 평균을 다시 계산
--
--    team_members_sync_fill(filled_count) 과 같은 자리에 붙는다.
--    출생연도가 없는 팀원은 평균에서 빼고 센다. 전원이 없으면 null.
--
--    set_config(..., true) 는 트랜잭션 한정 설정이다. 8번 가드가
--    "이 update 는 내가 한 것"을 알아보는 표식으로 쓴다.
-- ------------------------------------------------------------
create or replace function sync_team_avg_age()
returns trigger language plpgsql security definer
set search_path = public as $$
declare
  v_team_id uuid := coalesce(new.team_id, old.team_id);
  v_avg     int;
begin
  select round(avg(korean_age(p.birth_year)))::int
  into v_avg
  from team_members m
  join profiles p on p.id = m.user_id
  where m.team_id = v_team_id
    and p.birth_year is not null;

  perform set_config('app.sync_avg_age', 'on', true);
  update teams set avg_age = v_avg where id = v_team_id;
  perform set_config('app.sync_avg_age', 'off', true);

  return coalesce(new, old);
end; $$;

drop trigger if exists team_members_sync_avg_age on team_members;
create trigger team_members_sync_avg_age
after insert or delete on team_members
for each row execute function sync_team_avg_age();


-- ------------------------------------------------------------
-- 8. 클라이언트가 보낸 avg_age 는 무시한다
--
--    예외를 던지지 않고 조용히 되돌리는 이유: 옛 버전 앱이 팀 정보 수정에
--    avg_age 를 실어 보내면 제목·내용 수정까지 통째로 실패한다. 계산 컬럼은
--    "네가 뭘 보내든 서버 값이 맞다" 로 처리하는 편이 안전하다.
-- ------------------------------------------------------------
create or replace function guard_team_avg_age()
returns trigger language plpgsql as $$
begin
  if new.avg_age is distinct from old.avg_age
     and coalesce(current_setting('app.sync_avg_age', true), 'off') <> 'on'
  then
    new.avg_age := old.avg_age;
  end if;
  return new;
end; $$;

drop trigger if exists teams_guard_avg_age on teams;
create trigger teams_guard_avg_age
before update on teams
for each row execute function guard_team_avg_age();


-- ------------------------------------------------------------
-- 9. 태그 상한 (자유 입력 대비)
--    write.tsx 가 최대 3개 · 12자로 막지만, 화면 규칙은 화면에만 있다.
--
--    check 제약에는 서브쿼리를 못 쓰므로 immutable 함수로 감싼다.
-- ------------------------------------------------------------
create or replace function tags_are_bounded(p_tags text[])
returns boolean language sql immutable as $$
  select coalesce(array_length(p_tags, 1), 0) <= 3
     -- 빈 배열이면 bool_and 가 null 이라 coalesce 로 통과시킨다
     and coalesce(bool_and(char_length(t) between 1 and 13), true)  -- '#' + 12자
  from unnest(coalesce(p_tags, '{}'::text[])) as t;
$$;

alter table teams drop constraint if exists teams_tags_bounded;
alter table teams add constraint teams_tags_bounded
  check (tags_are_bounded(tags));


-- ------------------------------------------------------------
-- 10. 기존 팀 평균 다시 계산 (한 번만 돌면 된다)
--    출생연도가 있는 팀원이 하나도 없는 팀은 null 이 된다.
--    (상관 서브쿼리라 그런 팀도 빠짐없이 null 로 덮인다.)
-- ------------------------------------------------------------
do $$
begin
  perform set_config('app.sync_avg_age', 'on', true);

  update teams t
  set avg_age = (
    select round(avg(korean_age(p.birth_year)))::int
    from team_members m
    join profiles p on p.id = m.user_id
    where m.team_id = t.id
      and p.birth_year is not null
  );

  perform set_config('app.sync_avg_age', 'off', true);
end $$;


-- ------------------------------------------------------------
-- 11. 확인
-- ------------------------------------------------------------
-- select t.title, t.avg_age, count(p.birth_year) as 나이있는팀원
-- from teams t
-- left join team_members m on m.team_id = t.id
-- left join profiles p on p.id = m.user_id
-- group by t.id, t.title, t.avg_age;
