-- ============================================================
-- 마이그레이션 015 — 오래된 알림 정리
--
-- 알림은 지우는 사람이 없다. 앱에 '알림 삭제' 버튼이 없고(있어도 아무도
-- 안 누른다), 012 는 계속 넣기만 한다. 한 사람이 매칭 한 번을 겪을 때마다
-- 대여섯 줄이 쌓이므로, 두 학기쯤 지나면 목록 조회가 인덱스를 타고도
-- 느려지고 백업만 커진다.
--
-- 규칙 — 읽은 것은 30일, 안 읽은 것도 90일
--   읽은 알림은 이미 제 할 일을 끝냈다. 30일이면 "지난주에 뭐였더라"를
--   되짚기에 충분하다.
--   안 읽은 알림을 남겨 두는 이유는 뱃지 숫자 때문이다 — 지우면 안 읽은
--   개수가 소리 없이 줄어 사용자가 놓친 것을 영영 모른다. 그래도 석 달이
--   지나면 그건 놓친 게 아니라 안 볼 알림이다.
--
-- 왜 트리거가 아니라 예약 작업인가
--   insert 마다 오래된 줄을 지우면(자주 쓰는 요령) 매칭 수락 트랜잭션에
--   delete 가 얹힌다. 정리는 급한 일이 아니므로 한가한 시간에 몰아서 한다.
--
-- 실행: Supabase Dashboard → SQL Editor 에 통째로 붙여넣고 Run
--       (전제: 마이그레이션 012)
--       여러 번 돌려도 안전하다. 예약도 다시 걸린다.
-- ============================================================


-- ------------------------------------------------------------
-- 1. 정리 함수
--
--    예약에 SQL 을 직접 박지 않고 함수로 감싼 이유:
--      · 손으로 한 번 돌려보고 몇 줄이 지워지는지 볼 수 있다
--      · 보관 기간을 바꿀 때 cron 예약을 건드리지 않아도 된다
-- ------------------------------------------------------------
create or replace function purge_old_notifications()
returns int language plpgsql security definer
set search_path = public as $$
declare
  v_count int;
begin
  delete from notifications
  where (read_at is not null and created_at < now() - interval '30 days')
     or (created_at < now() - interval '90 days');

  get diagnostics v_count = row_count;
  return v_count;
end; $$;

comment on function purge_old_notifications() is
  '읽은 알림 30일 / 전체 90일 지난 것을 지운다. pg_cron 이 매일 부른다 (마이그레이션 015)';

-- 운영용이다. 앱에서 부를 일이 없다.
revoke all on function purge_old_notifications() from public;
revoke all on function purge_old_notifications() from anon;
revoke all on function purge_old_notifications() from authenticated;


-- ------------------------------------------------------------
-- 2. 매일 한 번 예약
--
--    pg_cron 의 시각은 UTC 다. 한국 시간 새벽 4시가 19:00 UTC 다.
--    (사람이 가장 안 쓰는 시간을 고른 것이라 정확할 필요는 없다)
--
--    ⚠️ 전체를 exception 으로 감쌌다.
--       pg_cron 을 못 켜는 환경이라도 1번의 정리 함수는 이미 만들어졌고,
--       그러면 손으로 가끔 돌리면 된다. 예약 하나 때문에 마이그레이션
--       전체가 실패해서 함수까지 없던 일이 되면 곤란하다.
-- ------------------------------------------------------------
do $$
begin
  execute 'create extension if not exists pg_cron';

  -- cron.schedule 은 같은 이름이 있으면 덮어쓰지만, 버전에 따라 중복으로
  -- 쌓이는 경우가 있다. 지우고 다시 건다.
  if exists (select 1 from cron.job where jobname = 'purge-old-notifications') then
    perform cron.unschedule('purge-old-notifications');
  end if;

  perform cron.schedule(
    'purge-old-notifications',
    '0 19 * * *',                                   -- 매일 04:00 KST
    $q$select public.purge_old_notifications();$q$  -- 예약은 검색 경로가 없다. 스키마까지 적는다.
  );

  raise notice '[알림 정리] 매일 04:00 (KST) 로 예약했습니다.';

exception when others then
  raise warning
    '[알림 정리] 예약을 걸지 못했습니다: %. '
    'Dashboard → Database → Extensions 에서 pg_cron 을 켠 뒤 이 파일을 '
    '다시 실행하세요. 그때까지는 purge_old_notifications() 를 손으로 부르면 됩니다.',
    sqlerrm;
end $$;


-- ------------------------------------------------------------
-- 3. 확인
-- ------------------------------------------------------------
-- -- (1) 예약이 걸렸나
-- select jobid, jobname, schedule, command, active
-- from cron.job where jobname = 'purge-old-notifications';
--
-- -- (2) 실제로 돌았나 (최근 실행 기록)
-- select start_time, status, return_message
-- from cron.job_run_details
-- where jobname = 'purge-old-notifications'
-- order by start_time desc
-- limit 10;
--
-- -- (3) 지금 당장 한 번 돌려보기 — 지워진 줄 수를 돌려준다
-- -- select purge_old_notifications();
--
-- -- (4) 지금 얼마나 쌓여 있나
-- select count(*) filter (where read_at is null)                       as 안읽음,
--        count(*) filter (where read_at is not null)                   as 읽음,
--        count(*) filter (where created_at < now() - interval '30 days') as "30일_지남",
--        count(*)                                                      as 전체
-- from notifications;
--
-- -- (5) 보관 기간을 바꾸려면 1번 함수의 interval 두 개만 고쳐 다시 실행한다.
-- --     예약은 함수 이름만 부르므로 손댈 필요가 없다.
