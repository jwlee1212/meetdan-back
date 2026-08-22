-- ============================================================
-- 마이그레이션 004 — 초대 코드 서버 발급
--
-- 문제
--   teams.invite_code 는 unique + '^[A-Z0-9]{6}$' 제약만 있고 기본값이 없다.
--   그래서 코드를 클라이언트가 만들어 보내야 했는데(write.tsx 의
--   Math.random().toString(36).substring(2, 8)), 두 가지가 어긋난다.
--     · 길이가 6이 아닐 수 있다. Math.random() 이 짧은 소수를 뱉으면
--       잘라낸 문자열이 5자 이하가 되고, check 제약에 걸려 팀 생성이 실패한다.
--     · 중복을 검사할 수 없다. teams_select 는 남의 비공개 팀을 숨기므로
--       클라이언트는 코드가 이미 쓰이는지 알 방법이 없다. 부딪히면 23505.
--
-- 해결
--   BEFORE INSERT 트리거로 서버가 발급한다. 비어 있을 때만 채우므로
--   관리자가 코드를 직접 지정하는 길은 남는다.
--
--   중복 검사는 security definer 로 돈다. teams_select 를 그대로 받으면
--   보이지 않는 팀의 코드와 부딪혀도 '비어 있다'고 판단해 버린다.
--
-- 실행: Supabase Dashboard → SQL Editor 에 통째로 붙여넣고 Run
-- ============================================================

create or replace function gen_invite_code()
returns text language plpgsql security definer
set search_path = public as $$
declare
  -- 사람이 받아 적는 코드라 헷갈리는 0/O/1/I 는 뺐다 (32자)
  v_alphabet constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  v_code text;
begin
  for i in 1..20 loop
    select string_agg(
             substr(v_alphabet, (floor(random() * length(v_alphabet)) + 1)::int, 1),
             ''
           )
      into v_code
      from generate_series(1, 6);

    if not exists (select 1 from teams where invite_code = v_code) then
      return v_code;
    end if;
  end loop;

  -- 32^6 ≈ 10억 가지라 20번이 전부 부딪히는 건 사실상 불가능하다.
  -- 여기까지 왔다면 코드 공간이 아니라 다른 곳이 고장 난 것이다.
  raise exception '초대 코드를 발급하지 못했습니다';
end; $$;

create or replace function set_team_invite_code()
returns trigger language plpgsql as $$
begin
  if new.invite_code is null then
    new.invite_code := gen_invite_code();
  end if;
  return new;
end; $$;

drop trigger if exists teams_set_invite_code on teams;
create trigger teams_set_invite_code
before insert on teams
for each row execute function set_team_invite_code();
