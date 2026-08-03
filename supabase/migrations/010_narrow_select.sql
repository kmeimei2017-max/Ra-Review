-- ============================================================
-- 라리뷰 Script H — 열람 범위 좁히기 (2단계: 문 잠그기)
--
-- 003_rls_policies.sql 의 읽기 정책이 using (true) 라, 앱 화면엔 3건만 보여도
-- anon 키로 REST 를 직접 부르면 trips 전체가 조회됐다(2026-08-03 확인: 17건).
-- 회원이 늘면 남의 후기 목록이 통째로 노출된다.
--
-- 이 스크립트가 그 문을 잠근다.
--
--   비회원(anon)          → 기본 후기(is_template)만
--   회원(authenticated)   → 자기 후기만
--   관리자                → 전부 (아래 🚨 참고 — 없으면 삭제 기능이 깨진다)
--   링크를 받은 사람      → trip_by_token() 으로 그 후기 하나만
--
-- ⚠️ 선행 조건 — 이걸 먼저 하지 않으면 앱과 카톡 공유가 죽는다.
--    ① 009_share_token.sql 실행 완료
--    ② index.html 이 loadTripByToken() / ?view=<토큰> 으로 배포 완료
--    ③ cloudflare-worker/og.js 가 trip_by_token RPC 로 배포 완료
--    셋 다 2026-08-03 확인 완료.
--
-- 🚨 trip_by_token() 의 anon 실행 권한은 절대 막지 말 것.
--    이 스크립트로 목록을 좁혔기 때문에, 이제 카톡으로 받은 링크를 여는 유일한 통로가
--    그 함수다. 막으면 공유가 통째로 죽는다(= 이 앱의 존재 이유).
--
-- 건드리지 않는 것: INSERT/UPDATE/DELETE 정책, Storage 정책.
-- ============================================================

begin;

-- ── 1) 후기가 "보여도 되는가" 판정 헬퍼 ─────────────────────
-- ★ photos 정책에서 trips 를 직접 참조하면 trips 의 RLS 를 다시 타서 재귀에 걸린다.
--   기존 trip_author()(002) 와 같은 방식으로 security definer 함수를 거쳐 우회한다.
create or replace function public.trip_visible(p_trip_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.trips t
     where t.id = p_trip_id
       and (t.is_template or t.author_id = auth.uid() or public.is_admin())
  );
$$;

comment on function public.trip_visible(uuid) is
  '이 후기를 지금 요청자가 목록에서 볼 수 있는가. photos 정책이 재귀를 피해 쓰는 헬퍼.';

grant execute on function public.trip_visible(uuid) to anon, authenticated;


-- ── 2) trips 읽기 좁히기 ────────────────────────────────────
-- ★ PERMISSIVE 정책은 OR 로 합쳐진다. 옛 정책(using (true))을 남기면
--   새 정책을 아무리 잘 써도 아무것도 좁혀지지 않는다. 반드시 먼저 지운다.
drop policy if exists trips_select_public on public.trips;
drop policy if exists trips_select_scoped on public.trips;

-- 🚨 public.is_admin() 조건을 빼지 말 것.
--    index.html 의 deleteTrip() 은 delete(...).select('id') 로 "실제 지워진 행"을 센다.
--    RETURNING 은 SELECT 정책의 영향을 받으므로, 관리자가 남의 후기를 지우면
--    실제로는 지워지고도 0행이 돌아와 "삭제 권한이 없어요" 가 뜬다.
--    (관리자가 앱 피드에서 남의 후기를 보게 되는 건 아니다 — loadTrips() 가
--     author_id 로 한 번 더 좁힌다. 화면 필터와 권한은 별개다.)
create policy trips_select_scoped on public.trips
  for select to anon, authenticated
  using (
    is_template                    -- 기본 후기 1·2·3 — 비회원 첫 화면
    or author_id = auth.uid()      -- 내 후기 (anon 이면 auth.uid() 가 null 이라 false)
    or public.is_admin()
  );


-- ── 3) photos 읽기 좁히기 (부모 trips 기준) ─────────────────
drop policy if exists photos_select_public on public.photos;
drop policy if exists photos_select_scoped on public.photos;

create policy photos_select_scoped on public.photos
  for select to anon, authenticated
  using (public.trip_visible(trip_id));

commit;


-- ============================================================
-- 실행 직후 확인
-- ============================================================
-- ⚠️ SQL Editor 는 postgres 역할로 돌아 RLS 를 통과해 버린다.
--    그래서 아래처럼 role 을 바꿔 "손님이 보면 몇 건인가" 를 흉내낸다.

-- 1) 비회원 눈에는 기본 후기만 보이는가 → trips_seen 이 3 이어야 한다
begin;
  set local role anon;
  select count(*) as trips_seen from public.trips;
rollback;

-- 2) 비회원 눈에 사진은 그 3건 것만 보이는가 → 기본 후기 사진 수와 같아야 한다
begin;
  set local role anon;
  select count(*) as photos_seen from public.photos;
rollback;

-- 3) 비교용 — 실제 전체 건수 (postgres 역할이라 RLS 를 통과한다)
select count(*) as trips_total,
       count(*) filter (where is_template) as templates
  from public.trips;

-- 4) 토큰 통로는 살아 있는가 → 후기 제목이 나와야 한다 (여기가 죽으면 공유가 죽는다)
begin;
  set local role anon;
  select public.trip_by_token(
           (select share_token from public.trips where not is_template limit 1)
         ) -> 'caption' as shared_caption;
rollback;

-- 5) 정책이 의도대로 걸렸는지 눈으로 확인
select tablename, policyname, cmd, roles, qual
  from pg_policies
 where schemaname = 'public' and tablename in ('trips','photos') and cmd = 'SELECT'
 order by tablename;


-- ============================================================
-- 롤백 — 앱이 깨졌을 때 즉시 되돌리기
-- ============================================================
-- begin;
-- drop policy if exists trips_select_scoped  on public.trips;
-- drop policy if exists photos_select_scoped on public.photos;
-- create policy trips_select_public  on public.trips  for select to anon, authenticated using (true);
-- create policy photos_select_public on public.photos for select to anon, authenticated using (true);
-- commit;
-- -- trip_visible() 은 남겨둬도 무해하다(아무도 호출하지 않게 된다).
