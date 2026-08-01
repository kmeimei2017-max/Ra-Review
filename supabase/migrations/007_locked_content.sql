-- ============================================================
-- 라봉후기 Script F — 잠긴(수정·삭제 불가) 후기
-- (ROADMAP "② 설명서 후기 — 편집 불가한 다시보기 자료")
--
-- 선행 조건: 001~006 실행 완료
-- 실행: Supabase 대시보드 > SQL Editor 에 전체 붙여넣고 Run
--
-- 설명서 후기는 "만질 수 없는 참고 자료"여야 한다. 실수로 고치거나 지우면
-- 다시 볼 방법이 없어진다. 그래서 앱 화면(index.html)에서 수정·삭제 버튼을
-- 숨기는 게 아니라, "잠김" 표시를 데이터에 직접 둔다 — 화면 코드가 이 값을
-- 그냥 따라가기만 하면 되므로 앱 쪽 수정이 최소화된다.
--
-- ⚠️ RLS 정책은 건드리지 않는다. 잠김은 화면에서 버튼을 숨기는 용도일 뿐,
--    DB 쓰기 권한 자체를 막는 게 아니다(막으면 매 요청마다 서버 오류가 난다).
-- ============================================================

begin;

-- ── 1) 컬럼 1개 ─────────────────────────────────────────────
alter table public.trips add column if not exists locked boolean not null default false;

comment on column public.trips.locked is 'true면 수정·삭제 버튼이 화면에서 숨는다(canEditTrip/canDeleteTrip). 소유자라도 못 건드림.';

-- ── 2) 가입 시 복사에도 잠김이 이어지게 ─────────────────────
-- 005 의 seed_templates_for_new_member() 를 다시 정의한다. is_template=false 는
-- 그대로(복사본이 또 복사되면 안 되니까) — locked 만 원본 값을 그대로 물려준다.
create or replace function public.seed_templates_for_new_member()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_src    record;
  v_new_id uuid;
  v_i      int := 0;
begin
  for v_src in
    select id, caption, thumb_url, locked
    from public.trips
    where is_template
    order by created_at desc
  loop
    insert into public.trips (caption, thumb_url, author_id, is_template, locked, seeded_from, created_at)
    values (v_src.caption, v_src.thumb_url, new.id, false, v_src.locked, v_src.id,
            now() - (v_i * interval '1 minute'))
    returning id into v_new_id;

    insert into public.photos (trip_id, url, content, order_index, type)
    select v_new_id, p.url, p.content, p.order_index, coalesce(p.type, 'image')
    from public.photos p
    where p.trip_id = v_src.id;

    v_i := v_i + 1;
  end loop;

  return new;
exception when others then
  raise warning '[rabong] 기본 후기 복사 실패 (uid=%): %', new.id, sqlerrm;
  return new;
end;
$$;

-- ── 3) 관리자 도구 — 잠그기/풀기 ─────────────────────────────
-- 004 의 admin.resolve_trip() 을 그대로 쓴다(제목으로 아무 후기나 찾음, 템플릿 한정 아님).
-- ★ 템플릿과 "내가 이미 가입 때 받은 복사본"은 서로 다른 행이다. 템플릿만 잠그면
--   그 이후 가입자에게만 적용되고, 이미 받은 복사본(관리자 자신 것 포함)은 안 바뀐다.
--   지금 당장 눈에 보이는 후기를 잠그려면 그 후기 제목으로 한 번 더 불러야 한다.
create or replace function admin.set_locked(p_key text, p_on boolean default true)
returns text
language plpgsql
as $$
declare v_id uuid; v_cap text;
begin
  v_id := admin.resolve_trip(p_key);

  update public.trips set locked = p_on where id = v_id
    returning coalesce(caption, '(제목 없음)') into v_cap;

  return format('%s — %s (%s)', case when p_on then '잠금' else '잠금 해제' end, v_cap, v_id);
end;
$$;

-- ── 4) 기존 뷰 갱신 ─────────────────────────────────────────
-- create or replace view 는 컬럼을 "끝에만" 추가할 수 있다. 순서를 지킬 것.
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
  t.locked
from public.trips t
left join public.profiles p on p.id = t.author_id
left join public.photos  ph on ph.trip_id = t.id
group by t.id, p.nickname, t.caption, t.created_at, t.author_id, t.is_template, t.seeded_from, t.locked
order by t.created_at desc;

comment on view admin.reviews is '후기 목록. is_template=가입 시 복사되는 원본, seeded_from=복사받은 것, locked=수정·삭제 불가.';

revoke execute on all functions in schema admin from public, anon, authenticated;

commit;


-- ============================================================
-- 지금 바로 적용 — 설명서 후기 잠그기
-- ============================================================
-- ① 템플릿(앞으로 가입할 사람들이 받을 원본)을 잠근다
select admin.set_locked('세로로 한 장이면 충분해요');

-- ② 관리자 본인이 가입 때 이미 받은 복사본도 잠근다(지금 피드에 보이는 그 카드)
--    복사본은 원본과 제목이 같으므로 admin.resolve_trip() 이 여러 건을 찾으면
--    후보 UUID 목록을 보여준다 — 그중 seeded_from 이 있는(복사본) 것으로 다시 부르면 된다.
--    예: select admin.set_locked('아래에서 확인한 UUID');
select id, caption, is_template, seeded_from, locked
from public.trips
where caption = '세로로 한 장이면 충분해요';


-- ============================================================
-- 사용법
-- ============================================================
-- 잠그기:     select admin.set_locked('제목 일부');
-- 풀기:       select admin.set_locked('제목 일부', false);
-- 확인:       select id, caption, locked, is_template from admin.reviews where locked;
--
-- 잠긴 후기는 앱에서 편집 진입(좌스와이프)이 조용히 무시되고,
-- 보내기·삭제 버튼이 둘 다 화면에서 사라진다(사진 안에 이미 버튼 그림이 있어서 겹쳐 보이기 때문).


-- ============================================================
-- 롤백
-- ============================================================
-- begin;
-- drop function if exists admin.set_locked(text, boolean);
-- update public.trips set locked = false;  -- 되돌리려면
-- alter table public.trips drop column locked;
-- -- admin.reviews 뷰는 005 정의로 되돌려야 한다.
-- -- seed_templates_for_new_member() 는 005 정의로 되돌려야 한다(locked 컬럼 참조 제거).
-- commit;
