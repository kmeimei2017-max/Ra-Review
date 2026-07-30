-- ============================================================
-- 라봉후기 Script D — 가입 시 기본 후기 3개 자동 생성
-- (ROADMAP "개인 피드 전환 + 기본 후기")
--
-- 선행 조건: 001~004 실행 완료
-- 실행: Supabase 대시보드 > SQL Editor 에 전체 붙여넣고 Run
--
-- 메인화면이 "내 후기만" 보이도록 바뀌면서, 새로 가입한 회원의 첫 화면이 텅 빈다.
-- 그래서 가입하는 순간 관리자가 만들어 둔 후기(템플릿)를 그 회원 것으로 복사해 준다.
-- 이 기본 후기 3개가 곧 사용설명서 역할을 한다.
--
-- ⚠️ RLS 정책은 건드리지 않는다. "개인 피드"는 앱 화면에서 골라 보여주는 것일 뿐
--    권한 변경이 아니다. 익명 SELECT 를 좁히면 카톡 미리보기 워커가 죽는다.
-- ============================================================

begin;

-- ── 1) 컬럼 2개 ─────────────────────────────────────────────
alter table public.trips add column if not exists is_template boolean not null default false;
alter table public.trips add column if not exists seeded_from uuid;

comment on column public.trips.is_template is 'true면 가입 시 새 회원에게 복사되는 원본. 관리자만 admin.set_template()으로 지정.';
comment on column public.trips.seeded_from is '가입 때 복사받은 후기면 원본 template의 id. 직접 쓴 후기는 null.';

-- seeded_from 이 있어야 "직접 쓴 후기"와 "가입 때 받은 후기"를 구분할 수 있다.
-- 없으면 모든 회원의 후기 수가 3부터 시작해서 활동량 판단이 무의미해진다.

create index if not exists trips_is_template_idx on public.trips (is_template) where is_template;

-- ── 2) 가입 시 기본 후기 복사 트리거 ────────────────────────
-- ★★ 사진 파일(Storage)은 복사하지 않고 URL 만 재사용한다 ★★
--   회원 수만큼 저장소가 불어나는 걸 막기 위해서다. 안전한 근거는 두 가지:
--     ① deleteTrip() 은 storage.list(trip.id) 로 "자기 후기 폴더"만 지운다.
--        복사본은 자기 폴더가 없으므로 목록이 비고, 원본 파일은 지워지지 않는다.
--     ② removePhoto() 는 화면 배열에서만 빼고 Storage 를 건드리지 않는다.
--   ⚠️ 이 전제가 깨지면 회원 전원의 기본 후기 사진이 한꺼번에 깨진다.
--      index.html 의 삭제 로직을 "URL 기준"으로 바꾸면 절대 안 된다.
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
  -- 최신 템플릿부터 돌면서 가입 시각 기준으로 시간을 다시 매긴다.
  -- 원본 created_at 을 그대로 쓰면 반년 뒤 가입한 사람 피드에 반년 전 날짜가 찍힌다.
  -- 이렇게 하면 상대 순서는 그대로면서, 회원이 새로 쓴 후기가 항상 맨 위에 온다.
  for v_src in
    select id, caption, thumb_url
    from public.trips
    where is_template
    order by created_at desc
  loop
    -- ★ 복사본은 반드시 is_template = false.
    --   true 로 두면 이 회원의 후기가 다음 가입자에게 다시 복사되어 눈덩이처럼 불어난다.
    insert into public.trips (caption, thumb_url, author_id, is_template, seeded_from, created_at)
    values (v_src.caption, v_src.thumb_url, new.id, false, v_src.id,
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
  -- ★ 이 트리거는 profiles INSERT 안에서 돌고, 그 profiles INSERT 는 auth.users 트리거
  --   안에서 돈다. 여기서 에러를 그냥 던지면 프로필 생성이 통째로 롤백되고,
  --   최악의 경우 회원가입 자체가 실패한다.
  --   기본 후기는 부가 기능이므로 실패해도 가입은 반드시 통과시킨다.
  raise warning '[rabong] 기본 후기 복사 실패 (uid=%): %', new.id, sqlerrm;
  return new;
end;
$$;

-- profiles 는 첫 로그인에만 INSERT 된다.
-- 재로그인은 001 의 upsert 가 UPDATE 경로를 타므로 AFTER INSERT 가 걸리지 않는다 → 1회만 복사.
drop trigger if exists trg_seed_templates on public.profiles;
create trigger trg_seed_templates
  after insert on public.profiles
  for each row execute function public.seed_templates_for_new_member();

-- ── 3) 관리자 도구 (004 의 admin 스키마에 이어붙임) ─────────

-- 후기 찾기 — 004 의 resolve_member() 와 같은 "정확히 1건 아니면 예외" 패턴.
-- 엉뚱한 후기를 템플릿으로 지정하는 사고를 막는다.
create or replace function admin.resolve_trip(p_key text)
returns uuid
language plpgsql
stable
as $$
declare
  v_id   uuid;
  v_cnt  int;
  v_list text;
begin
  p_key := btrim(coalesce(p_key, ''));
  if p_key = '' then
    raise exception '후기 제목 또는 UUID를 입력하세요. (admin.reviews 에서 확인)';
  end if;

  if p_key ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select t.id into v_id from public.trips t where t.id = p_key::uuid;
    if v_id is null then
      raise exception '그런 후기가 없습니다: %', p_key;
    end if;
    return v_id;
  end if;

  select count(*) into v_cnt from public.trips t where t.caption = p_key;

  if v_cnt = 0 then
    raise exception '제목이 "%" 인 후기가 없습니다. admin.reviews 에서 확인하세요.', p_key;
  elsif v_cnt > 1 then
    select string_agg(format('%s  (%s)', t.id, t.caption), E'\n')
      into v_list
      from public.trips t where t.caption = p_key;
    raise exception '제목이 "%" 인 후기가 %건입니다. 아래 UUID 중 하나로 다시 호출하세요.', p_key, v_cnt
      using hint = v_list;
  end if;

  select t.id into v_id from public.trips t where t.caption = p_key;
  return v_id;
end;
$$;

-- 템플릿 지정 / 해제
create or replace function admin.set_template(p_key text, p_on boolean default true)
returns text
language plpgsql
as $$
declare v_id uuid; v_cap text; v_cnt int;
begin
  v_id := admin.resolve_trip(p_key);

  if p_on and exists (select 1 from public.trips where id = v_id and seeded_from is not null) then
    raise exception '가입 때 복사받은 후기는 템플릿으로 지정할 수 없습니다. 원본을 지정하세요.';
  end if;

  update public.trips set is_template = p_on where id = v_id
    returning coalesce(caption, '(제목 없음)') into v_cap;

  select count(*) into v_cnt from public.trips where is_template;

  return format('%s — %s (%s) · 현재 템플릿 %s개',
                case when p_on then '템플릿 지정' else '템플릿 해제' end,
                v_cap, v_id, v_cnt);
end;
$$;

-- ── 4) 기존 뷰 갱신 ─────────────────────────────────────────
-- create or replace view 는 컬럼을 "끝에만" 추가할 수 있다. 순서를 지킬 것.

-- 후기 수는 "직접 쓴 것"만 센다. 가입 때 받은 3개까지 세면 활동량 판단이 안 된다.
create or replace view admin.members as
select
  p.id,
  coalesce(p.nickname, '(닉네임 없음)') as nickname,
  p.is_admin,
  p.is_blocked,
  p.created_at         as joined_at,
  count(distinct t.id) filter (where t.seeded_from is null) as trip_count,
  count(ph.id)         filter (where t.seeded_from is null) as photo_count,
  count(distinct t.id) filter (where t.seeded_from is not null) as seeded_count
from public.profiles p
left join public.trips  t  on t.author_id = p.id
left join public.photos ph on ph.trip_id  = t.id
group by p.id, p.nickname, p.is_admin, p.is_blocked, p.created_at
order by p.created_at;

comment on view admin.members is '회원 목록. trip_count=직접 쓴 후기, seeded_count=가입 때 받은 기본 후기.';

create or replace view admin.reviews as
select
  t.id,
  coalesce(p.nickname, '(작성자 없음)')                     as author,
  replace(left(coalesce(t.caption, ''), 40), E'\n', ' ')    as caption,
  count(ph.id)                                             as photo_count,
  t.created_at,
  t.author_id,
  t.is_template,
  t.seeded_from
from public.trips t
left join public.profiles p on p.id = t.author_id
left join public.photos  ph on ph.trip_id = t.id
group by t.id, p.nickname, t.caption, t.created_at, t.author_id, t.is_template, t.seeded_from
order by t.created_at desc;

comment on view admin.reviews is '후기 목록. is_template=가입 시 복사되는 원본, seeded_from=복사받은 것.';

-- ── 5) 접근 차단 재확인 ─────────────────────────────────────
revoke execute on all functions in schema admin from public, anon, authenticated;
revoke all     on all tables    in schema admin from public, anon, authenticated;

commit;


-- ============================================================
-- 실행 직후 확인
-- ============================================================
-- ★ 템플릿이 0개면 새로 가입한 회원은 빈 화면을 본다.
--   앱(index.html)을 배포하기 전에 반드시 3개를 지정할 것.
select count(*) as 템플릿_개수 from public.trips where is_template;

-- select * from admin.reviews;


-- ============================================================
-- 다음 수동 단계 — 템플릿 지정 (앱 배포 전 필수)
-- ============================================================
-- 1) 앱에서 기본 후기 3개를 평소처럼 작성한다
--      ① 설명서 후기  ② 테스트 후기  ③ 라리뷰 후기(개발 동기)
--
-- 2) 제목으로 지정한다 (피드 맨 위에 보이길 원하는 것을 마지막에 쓰면 된다)
--      select admin.set_template('설명서 후기 제목');
--      select admin.set_template('테스트 후기 제목');
--      select admin.set_template('라리뷰 후기 제목');
--
-- 3) 확인 — is_template 이 true 인 3건이 보여야 한다
--      select id, caption, is_template from public.trips where is_template;
--
-- 해제하려면:
--      select admin.set_template('후기 제목', false);
--
-- ⚠️ 템플릿으로 지정한 후기를 앱에서 삭제하면 이후 가입자가 그 후기를 못 받는다.
--    내용을 고치는 건 괜찮다 — 그 이후 가입자부터 반영된다.


-- ============================================================
-- 롤백
-- ============================================================
-- begin;
-- drop trigger if exists trg_seed_templates on public.profiles;
-- drop function if exists public.seed_templates_for_new_member();
-- drop function if exists admin.set_template(text, boolean);
-- drop function if exists admin.resolve_trip(text);
-- -- 컬럼과 복사된 후기는 남겨둔다. 지우려면(회원 데이터가 사라지니 주의):
-- --   delete from public.photos where trip_id in (select id from public.trips where seeded_from is not null);
-- --   delete from public.trips where seeded_from is not null;
-- --   alter table public.trips drop column seeded_from, drop column is_template;
-- commit;
-- ※ admin.members / admin.reviews 뷰는 004 의 정의로 되돌려야 한다.
