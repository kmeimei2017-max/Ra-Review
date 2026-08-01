-- ============================================================
-- 008 — 라리뷰 후기(③)도 잠금 대상에 넣기 + locked 의 뜻 정정
-- ============================================================
-- 선행 조건: 007 실행 완료
-- 실행: Supabase 대시보드 > SQL Editor 에 붙여넣고 Run
--
-- 잠금(locked)의 뜻이 007 때보다 좁아졌다.
--   007: 수정·삭제·편집 진입까지 전부 막음
--   008: 보내기·삭제 버튼(드로어)을 숨기고 삭제만 막는다.
--        좌우 스와이프 이동(좌=편집, 우=홈)은 잠긴 후기에서도 그대로 된다
--
-- 왜 바꿨나 — 미리보기페이지의 드로어에는 보내기·삭제 두 개뿐이고,
-- 화면을 빠져나가는 길은 원래부터 좌우 스와이프뿐이다. 잠긴 후기는 드로어가
-- 통째로 숨으므로 편집 진입까지 막으면 좌스와이프가 완전 무반응이 되고,
-- 관리자가 앱에서 안내 문구를 고칠 방법도 사라진다(설명서·라리뷰는 앞으로 계속 다듬을 글이다).
-- 클라이언트 쪽 대응은 index.html 의 canEditTrip() 한 줄이다.
-- ============================================================

-- ── 1) 컬럼 설명 갱신 (007 의 문구가 이제 사실과 다르다) ─────
comment on column public.trips.locked is
  'true면 보내기·삭제 버튼이 화면에서 숨고 삭제가 막힌다. 편집·좌우 스와이프 이동은 그대로.';


-- ============================================================
-- 지금 바로 적용 — 라리뷰 후기 잠그기
-- ============================================================
-- 기본 후기 제목은 화면 순서대로 번호가 앞에 붙어 있다.
--   1.여기부터~            (테스트) — 잠그지 않는다. 지워보는 게 이 후기의 용도다
--   2.세로로~              (설명서) — 007 에서 이미 잠금
--   3.Ra-Review 개발동기   (라리뷰) — 이번에 잠근다

-- ── ① 먼저 지금 상태를 확인한다 ─────────────────────────────
select id, caption, is_template, seeded_from, locked
from public.trips
order by created_at desc;

-- ── ② 라리뷰 후기를 잠근다 ─────────────────────────────────
--    ★ admin.set_locked() 를 안 쓰는 이유: 템플릿 원본과 "가입 때 받은 복사본"은
--      제목이 같은 별개의 행이라, 정확히 1건만 처리하는 resolve_trip() 이 매번 예외를 낸다.
--    ★ 제목 전체가 아니라 앞번호('3.')로 거는 이유: 뒷부분 표기가 바뀌어도(철자·띄어쓰기 등)
--      그대로 먹는다. is_template 이거나 그 복사본인 행으로 범위를 좁혀
--      회원이 직접 쓴 '3.' 로 시작하는 후기는 건드리지 않는다.
update public.trips set locked = true
where caption like '3.%'
  and (is_template or seeded_from is not null);

-- ── ③ 확인 — 2.설명서와 3.라리뷰가 원본·복사본까지 모두 나와야 한다 ──
select id, caption, is_template, seeded_from, locked
from public.trips
where locked
order by created_at desc;


-- ============================================================
-- 사용법
-- ============================================================
-- ℹ️ 잠금은 후기의 id 에 붙는다. 그래서 나중에 앱에서 제목·글·사진을 고쳐도 잠김은 유지된다
--    (is_template 과 같은 방식). 반대로 제목을 바꾼 뒤에는 위 caption 기준 SQL 이 안 먹으니
--    잠그는 건 내용을 고치기 전에 먼저 해둔다.
--
-- 한 건만 잠그기/풀기 (제목이 유일할 때):
--   select admin.set_locked('제목 일부');
--   select admin.set_locked('제목 일부', false);
--
-- 원본·복사본을 한 번에 (제목이 겹칠 때 — 앞번호로):
--   update public.trips set locked = true  where caption like '3.%' and (is_template or seeded_from is not null);
--   update public.trips set locked = false where caption like '3.%' and (is_template or seeded_from is not null);
--
-- 확인:
--   select id, caption, locked, is_template from admin.reviews where locked;


-- ============================================================
-- 롤백
-- ============================================================
-- update public.trips set locked = false where caption like '3.%' and (is_template or seeded_from is not null);
-- ※ index.html 의 canEditTrip() 은 코드로 되돌린다(SQL 아님).
