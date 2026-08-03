-- ============================================================
-- 라리뷰 Script G — 공유 토큰 (1단계: 준비)
--
-- 목적: 공유 링크를 "후기 아이디"에서 "추측 불가능한 열쇠"로 바꾸기 위한 밑작업.
--
--   지금 링크는  ?view=<후기 UUID>  라 아이디가 곧 주소다.
--   아이디는 이름표일 뿐이라, 다른 경로로 알아내면 그대로 열린다.
--   실제로 anon 키로 REST 를 직접 부르면 trips 전체가 조회된다(2026-08-03 확인: 17건).
--   이유는 003_rls_policies.sql 의 trips_select_public 이 using (true) 이기 때문.
--
-- ⚠️ 이 스크립트는 정책(RLS)을 건드리지 않는다. 실행해도 앱 동작은 그대로다.
--    보안이 좋아지지도 않는다. 좁히는 일은 2단계에서 한다.
--
-- 🚨 그래서 1단계에서 멈추면 안 된다.
--    지금은 anon SELECT 가 열려 있어 여기서 만든 share_token 까지 같이 읽힌다.
--    (열쇠를 만들어 문 앞에 걸어둔 상태 — 원래도 문이 열려 있었으니 더 나빠지진 않지만,
--     2단계까지 가야 의미가 생긴다.)
--
-- 2단계에서 할 일 (이 파일 아님):
--    index.html 과 cloudflare-worker/og.js 를 토큰 기반으로 바꿔 배포·확인한 뒤,
--    마지막에 trips/photos 의 anon SELECT 를 좁힌다.
--    그때도 아래 trip_by_token() 은 security definer 라 계속 동작한다 — 그게 이 함수의 존재 이유다.
--
-- 선행 조건: 001~008 실행 완료
-- 재실행: 안전하다(같은 스크립트를 여러 번 돌려도 토큰이 바뀌지 않는다).
-- ============================================================

begin;

-- ── 1) trips.share_token ────────────────────────────────────
-- 32자 hex. gen_random_uuid() 는 Postgres 코어 함수라 pgcrypto 확장이 필요 없다.
--
-- ★ 컬럼 추가 → 백필 → default 순서를 지킬 것.
--   default 를 단 채로 컬럼을 추가하면 기존 행이 전부 같은 값을 받을 수 있다
--   (Postgres 가 default 를 한 번만 계산해 채우는 최적화). 그러면 unique 가 깨진다.
alter table public.trips
  add column if not exists share_token text;

update public.trips
   set share_token = replace(gen_random_uuid()::text, '-', '')
 where share_token is null;

alter table public.trips
  alter column share_token set default replace(gen_random_uuid()::text, '-', '');

alter table public.trips
  alter column share_token set not null;

-- unique 제약이 인덱스를 겸한다 → 토큰 조회가 인덱스 스캔이 된다. 별도 인덱스 불필요.
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.trips'::regclass
       and conname  = 'trips_share_token_key'
  ) then
    alter table public.trips add constraint trips_share_token_key unique (share_token);
  end if;
end $$;

comment on column public.trips.share_token is
  '공유 링크용 열쇠(32자 hex). ?view= 에 실린다. 아이디와 달리 추측할 수 없다.';


-- ── 2) 토큰으로 후기 하나만 돌려주는 함수 ───────────────────
-- ★ security definer = RLS 를 우회한다. 2단계에서 trips 의 anon SELECT 를 막아도
--   토큰을 가진 사람은 이 함수로 계속 볼 수 있다. 그래서 service_role 키가 필요 없다.
--   (service_role 을 워커에 넣는 방식도 있지만, 관리할 비밀이 하나 더 느는 쪽이라 택하지 않았다.)
-- ★ set search_path 는 definer 함수의 필수 안전조치다. 빼면 호출자가 search_path 를 바꿔
--   엉뚱한 스키마의 trips 를 보게 만들 수 있다.
-- ★ 반환 모양은 앱의 select('*, photos(*)') 결과와 같게 맞춘다 →
--   index.html 의 shapeTrip() 이 그대로 받는다.
create or replace function public.trip_by_token(p_token text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select to_jsonb(t) || jsonb_build_object(
           'photos',
           coalesce(
             (select jsonb_agg(to_jsonb(ph) order by ph.order_index)
                from public.photos ph
               where ph.trip_id = t.id),
             '[]'::jsonb
           )
         )
    from public.trips t
   where t.share_token = p_token;
$$;

comment on function public.trip_by_token(text) is
  '공유 토큰으로 후기 1건 + 사진을 반환. 없으면 null. 카톡 링크와 OG 워커가 쓴다.';

-- 함수는 기본적으로 public 에 실행 권한이 붙는다 → 회수 후 필요한 역할에만 다시 준다.
revoke all on function public.trip_by_token(text) from public;
grant execute on function public.trip_by_token(text) to anon, authenticated;


-- ── 3) 관리자 뷰에 토큰 추가 ────────────────────────────────
-- 카톡 카드를 만들지 않고도 대시보드에서 링크를 뽑아 시험할 수 있어야 한다.
-- ★ create or replace view 는 "맨 뒤에 컬럼 추가"만 허용한다. 순서를 바꾸거나 빼면 실패한다.
-- ⚠️ 베이스는 004 가 아니라 007 의 정의다. admin.reviews 는 004 → 005 → 007 순으로
--    재정의돼 왔다(005 에서 is_template·seeded_from, 007 에서 locked 추가).
--    004 를 베껴 오면 그 컬럼들이 빠져 실행이 실패한다.
create or replace view admin.reviews as
select
  t.id,
  coalesce(p.nickname, '(작성자 없음)')                     as author,
  replace(left(coalesce(t.caption, ''), 40), E'\n', ' ')    as caption,
  count(ph.id)                                             as photo_count,
  t.created_at,
  t.author_id,
  t.is_template,
  t.seeded_from,
  t.locked,
  t.share_token
from public.trips t
left join public.profiles p on p.id = t.author_id
left join public.photos  ph on ph.trip_id = t.id
group by t.id, p.nickname, t.caption, t.created_at, t.author_id,
         t.is_template, t.seeded_from, t.locked, t.share_token
order by t.created_at desc;

comment on view admin.reviews is
  '후기 목록. is_template=가입 시 복사되는 원본, seeded_from=복사받은 것, locked=수정·삭제 불가, share_token=공유 링크 열쇠.';

commit;


-- ============================================================
-- 실행 직후 확인 (아래를 그대로 실행해 값을 눈으로 볼 것)
-- ============================================================

-- 1) 토큰이 전부 채워졌고 32자인가 → bad_rows 가 0 이어야 한다
select count(*) filter (where share_token is null or length(share_token) <> 32) as bad_rows,
       count(*)                                                                 as total
  from public.trips;

-- 2) 토큰이 서로 겹치지 않는가 → 두 값이 같아야 한다
select count(*) as total, count(distinct share_token) as distinct_tokens
  from public.trips;

-- 3) 함수가 도는가 → 후기 1건이 photos 배열과 함께 나와야 한다
select public.trip_by_token((select share_token from public.trips order by created_at desc limit 1))
       -> 'caption' as caption_check;

-- 4) 없는 토큰은 null 을 돌려주는가 → null 이어야 한다
select public.trip_by_token('0000000000000000000000000000ffff') as should_be_null;

-- 5) 링크 만들어 보기 (2단계 배포 전까지는 아직 열리지 않는다 — 형태만 확인)
select caption,
       'https://kmeimei2017-max.github.io/Ra-Review/?view=' || share_token as future_link
  from admin.reviews
 order by created_at desc
 limit 5;


-- ============================================================
-- 롤백 — 되돌리기
-- ============================================================
-- begin;
-- drop function if exists public.trip_by_token(text);
-- alter table public.trips drop constraint if exists trips_share_token_key;
-- alter table public.trips drop column if exists share_token;
-- -- admin.reviews 는 007_locked_content.sql 의 뷰 정의(4번 항목)를 다시 실행해 복구한다.
-- --   ⚠️ 004 가 아니다. 004 → 005 → 007 순으로 재정의돼 왔다.
-- commit;
