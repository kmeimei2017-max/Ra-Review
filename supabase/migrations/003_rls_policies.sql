-- ============================================================
-- 라봉후기 Script B-2 — RLS ON + 정책
-- (ROADMAP 카카오 로그인 2단계 본체)
--
-- 선행 조건: 001, 002 실행 완료 + index.html 수정본 배포 및 동작 확인
--
-- ⚠️ 이 스크립트를 실행하는 순간부터 비로그인 사용자의 후기 작성/수정/삭제는
--    즉시 전부 거부된다. 이것이 이 작업의 목적이다.
--    열람(피드 · ?view= · 카톡 OG 미리보기)은 익명 SELECT 를 열어두므로 영향 없다.
--
-- 정책 요약
--   읽기   : 전체 공개 (익명 포함)          ← 절대 좁히지 말 것 (아래 이유 참고)
--   쓰기   : 본인만, 차단 회원은 전면 불가
--   수정   : 본인만 (관리자도 남의 후기 수정 불가), 차단 회원 불가
--   삭제   : 본인 또는 관리자
-- ============================================================

begin;

-- ── 1) 기존 정책 정리 ───────────────────────────────────────
-- ★ PERMISSIVE 정책은 OR 로 합쳐진다.
--   예전의 "using (true)" INSERT 정책을 남겨두면 새 정책을 아무리 잘 써도 보안이 0이다.
--   반드시 먼저 전부 지운다.
do $$
declare r record;
begin
  for r in select policyname, tablename from pg_policies
           where schemaname = 'public' and tablename in ('trips','photos')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

alter table public.trips  enable row level security;
alter table public.photos enable row level security;

-- ── 2) trips ────────────────────────────────────────────────
-- ★★ 읽기는 전체 공개로 영구히 유지한다. 절대 좁히지 말 것 ★★
--   카톡/밴드 공유용 OG 워커가 anon 키로 trips/photos 를 직접 REST 조회한다:
--     cloudflare-worker/og.js        (실제 사용)
--     supabase/functions/og/index.ts (동일 제약의 레거시 사본)
--   service_role 을 쓰는 서버 코드가 없으므로, 여기를 막으면
--   카톡 미리보기와 비로그인 열람이 동시에 죽는다.
create policy trips_select_public on public.trips
  for select to anon, authenticated
  using (true);

create policy trips_insert_own on public.trips
  for insert to authenticated
  with check (author_id = auth.uid() and not public.is_blocked());

-- 수정: 본인만. 관리자도 남의 후기는 수정 불가(확정된 결정).
create policy trips_update_own on public.trips
  for update to authenticated
  using      (author_id = auth.uid() and not public.is_blocked())
  with check (author_id = auth.uid() and not public.is_blocked());

-- 삭제: 본인 또는 관리자
create policy trips_delete_own_or_admin on public.trips
  for delete to authenticated
  using (author_id = auth.uid() or public.is_admin());

-- ── 3) photos (소유권은 부모 trips 로 판정) ─────────────────
create policy photos_select_public on public.photos
  for select to anon, authenticated
  using (true);

create policy photos_insert_own on public.photos
  for insert to authenticated
  with check (public.trip_author(trip_id) = auth.uid() and not public.is_blocked());

create policy photos_update_own on public.photos
  for update to authenticated
  using      (public.trip_author(trip_id) = auth.uid() and not public.is_blocked())
  with check (public.trip_author(trip_id) = auth.uid() and not public.is_blocked());

create policy photos_delete_own_or_admin on public.photos
  for delete to authenticated
  using (public.trip_author(trip_id) = auth.uid() or public.is_admin());

-- ── 4) Storage: trip-photos 버킷 ────────────────────────────
-- 경로 규칙 = {trip_id}/{filename}
-- persistTrip() 이 trips insert 를 먼저 하므로 업로드 시점에 trips 행이 이미 있다
-- → 소유자 판정이 가능하다.
do $$
declare r record;
begin
  for r in select policyname from pg_policies
           where schemaname='storage' and tablename='objects'
             and (coalesce(qual,'') || coalesce(with_check,'')) like '%trip-photos%'
  loop
    execute format('drop policy %I on storage.objects', r.policyname);
  end loop;
end $$;

-- 읽기 공개.
-- ★ deleteTrip() 의 .storage.list() 는 CDN 이 아니라 API 를 타므로 SELECT 정책이 필요하다.
--   막으면 list 가 빈 배열을 돌려주고 파일이 조용히 고아로 남는다.
create policy tripphotos_read_public on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'trip-photos');

create policy tripphotos_insert_own on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'trip-photos'
    and public.storage_trip_owner(name) = auth.uid()
    and not public.is_blocked()
  );

create policy tripphotos_delete_own_or_admin on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'trip-photos'
    and (public.storage_trip_owner(name) = auth.uid() or public.is_admin())
  );

commit;


-- ============================================================
-- 실행 직후 반드시 확인
-- ============================================================
-- storage.objects 에 "trip-photos" 문자열이 없는 전체 허용 정책
-- (예: bucket_id is not null, true)이 남아 있으면 위 DO 블록이 못 잡는다.
-- OR 로 합쳐져 보안이 전부 무효화되므로 이름을 보고 수동으로 drop 해야 한다.
-- storage.objects 는 RLS 를 끌 수 없어 정책이 유일한 방어선이다.

select schemaname, tablename, policyname, cmd, roles, qual, with_check
from pg_policies
where (schemaname = 'public'  and tablename in ('trips','photos','profiles'))
   or (schemaname = 'storage' and tablename = 'objects')
order by schemaname, tablename, cmd, policyname;


-- ============================================================
-- 롤백 — 앱이 깨졌을 때 즉시 되돌리기
-- ============================================================
-- begin;
-- alter table public.trips  disable row level security;
-- alter table public.photos disable row level security;
-- -- storage.objects 는 RLS 를 끌 수 없다 → 임시 전체 허용 정책으로 복구
-- drop policy if exists tripphotos_insert_own          on storage.objects;
-- drop policy if exists tripphotos_delete_own_or_admin on storage.objects;
-- create policy tripphotos_temp_allow_all on storage.objects
--   for all to anon, authenticated
--   using (bucket_id = 'trip-photos') with check (bucket_id = 'trip-photos');
-- -- tripphotos_read_public 은 list/다운로드에 필요하므로 남긴다
-- commit;
