-- ============================================================
-- 마이그레이션 003 — profiles 고정 컬럼 보호
--
-- 문제
--   profiles_update RLS(dku_meeting_schema_v2.sql:458)는
--     using (id = auth.uid() or is_admin())
--     with check (id = auth.uid() or is_admin())
--   로 "본인 행인지"만 검사한다. 컬럼 단위 제한이 없어서, 로그인한
--   사용자가 마이 탭(API.updateMyProfile, nickname/bio/mbti/avatar_idx만
--   보냄)을 거치지 않고 supabase-js 로 직접
--     .from('profiles').update({ status: 'active', strike_count: 0, ... })
--   를 보내면 그대로 통과한다. 가입 시 확정 컬럼(login_id/name/email/
--   gender/campus/dept)과 운영 컬럼(status/strike_count/suspended_until/
--   deleted_at/email_verified_at)까지 본인이 직접 바꿀 수 있었다는 뜻이다.
--   (migration 002 주석에서 email_verified_at 하나에 대해 지적했던 것과
--   같은 종류의 구멍이 나머지 고정/운영 컬럼에도 그대로 있었다.)
--
-- 해결
--   BEFORE UPDATE 트리거로 관리자가 아닌 본인 수정에서 이 컬럼들이
--   바뀌면 거부한다. 마이 탭이 실제로 건드리는 nickname/bio/mbti/
--   avatar_idx 는 그대로 통과한다.
--
-- 실행: Supabase Dashboard → SQL Editor 에 통째로 붙여넣고 Run
-- ============================================================

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

  return new;
end;
$$;

drop trigger if exists profiles_guard_fixed_columns on profiles;
create trigger profiles_guard_fixed_columns
before update on profiles
for each row execute function guard_profile_update();
