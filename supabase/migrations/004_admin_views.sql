-- ============================================================
-- 라봉후기 Script C — 관리자 조회 뷰 + 회원관리 함수
-- (ROADMAP "Supabase 관리자 대시보드 및 회원관리")
--
-- 선행 조건: 001, 002, 003 실행 완료
-- 실행: Supabase 대시보드 > SQL Editor 에 전체 붙여넣고 Run
--
-- 이 스크립트는 기존 테이블·RLS 정책을 전혀 건드리지 않는다 → 앱 동작에 영향 0.
-- 앱(index.html) 안에는 관리자 화면을 만들지 않는다. 운영은 여기서 SQL로 한다.
-- ============================================================

begin;

-- ── 1) admin 스키마 ─────────────────────────────────────────
-- ★ public 이 아니라 별도 스키마에 두는 이유:
--   PostgREST 가 노출하는 스키마는 public 뿐이라, admin 스키마는 anon 키로
--   REST 에서 아예 도달할 수 없다. 회원 목록 뷰를 public 에 만들면
--   뷰가 소유자 권한으로 실행되어 profiles 의 RLS를 우회하므로
--   anon 이 전 회원 명단을 그대로 긁어갈 수 있다.
create schema if not exists admin;

revoke all on schema admin from public, anon, authenticated;

comment on schema admin is '관리자 전용 조회 뷰/함수. Supabase SQL Editor(postgres)에서만 사용. 앱은 접근 불가.';

-- ── 2) admin.members — 가입자 목록 ──────────────────────────
create or replace view admin.members as
select
  p.id,
  coalesce(p.nickname, '(닉네임 없음)') as nickname,
  p.is_admin,
  p.is_blocked,
  p.created_at         as joined_at,
  count(distinct t.id) as trip_count,
  count(ph.id)         as photo_count
from public.profiles p
left join public.trips  t  on t.author_id = p.id
left join public.photos ph on ph.trip_id  = t.id
group by p.id, p.nickname, p.is_admin, p.is_blocked, p.created_at
order by p.created_at;

comment on view admin.members is '회원 목록 + 회원별 후기·사진 수. 가입 순.';

-- ── 3) admin.reviews — 후기 목록 (문제 후기 찾기용) ─────────
-- author_id 가 NULL 인 후기(탈퇴로 소유자가 사라진 글)도 보이게 left join.
create or replace view admin.reviews as
select
  t.id,
  coalesce(p.nickname, '(작성자 없음)')                     as author,
  replace(left(coalesce(t.caption, ''), 40), E'\n', ' ')    as caption,
  count(ph.id)                                             as photo_count,
  t.created_at,
  t.author_id
from public.trips t
left join public.profiles p on p.id = t.author_id
left join public.photos  ph on ph.trip_id = t.id
group by t.id, p.nickname, t.caption, t.created_at, t.author_id
order by t.created_at desc;

comment on view admin.reviews is '후기 목록 + 작성자·사진 수. 최신 순.';

-- ── 4) 회원 찾기 헬퍼 ───────────────────────────────────────
-- ★ 닉네임과 UUID 를 한 함수로 받는다.
--   오버로드(text/uuid)로 나누면 admin.block('...') 의 인자 타입이 애매해져
--   UUID 를 넣어도 닉네임 쪽으로 해석되는 사고가 난다.
-- ★ 정확히 1명이 아니면 예외를 던진다 → 엉뚱한 사람을 차단하는 일을 막는다.
create or replace function admin.resolve_member(p_key text)
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
    raise exception '닉네임 또는 UUID를 입력하세요. (admin.members 에서 확인)';
  end if;

  -- UUID 를 그대로 넣은 경우
  if p_key ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select p.id into v_id from public.profiles p where p.id = p_key::uuid;
    if v_id is null then
      raise exception '그런 회원이 없습니다: %', p_key;
    end if;
    return v_id;
  end if;

  select count(*) into v_cnt from public.profiles p where p.nickname = p_key;

  if v_cnt = 0 then
    raise exception '닉네임 "%" 인 회원이 없습니다. admin.members 에서 확인하세요.', p_key;
  elsif v_cnt > 1 then
    select string_agg(format('%s  (%s)', p.id, p.nickname), E'\n')
      into v_list
      from public.profiles p where p.nickname = p_key;
    raise exception '닉네임 "%" 인 회원이 %명입니다. 아래 UUID 중 하나로 다시 호출하세요.', p_key, v_cnt
      using hint = v_list;
  end if;

  select p.id into v_id from public.profiles p where p.nickname = p_key;
  return v_id;
end;
$$;

-- ── 5) 회원관리 함수 ────────────────────────────────────────
-- ★ security definer 를 쓰지 않는다. SQL Editor 는 postgres 로 실행되므로
--   불필요하고, 붙이면 오히려 권한 유출 경로가 된다.
-- ★ 항상 "누가 어떻게 바뀌었는지"를 문장으로 돌려준다 (결과창에서 바로 확인).

-- 차단: 쓰기 전면 금지. 로그인·열람·기존 후기 노출은 그대로 유지된다.
create or replace function admin.block(p_key text)
returns text
language plpgsql
as $$
declare v_id uuid; v_nick text;
begin
  v_id := admin.resolve_member(p_key);
  update public.profiles set is_blocked = true where id = v_id
    returning coalesce(nickname, '(닉네임 없음)') into v_nick;
  return format('차단됨 — %s (%s) · 쓰기 전면 금지, 열람과 기존 후기는 그대로', v_nick, v_id);
end;
$$;

create or replace function admin.unblock(p_key text)
returns text
language plpgsql
as $$
declare v_id uuid; v_nick text;
begin
  v_id := admin.resolve_member(p_key);
  update public.profiles set is_blocked = false where id = v_id
    returning coalesce(nickname, '(닉네임 없음)') into v_nick;
  return format('차단 해제 — %s (%s) · 다시 후기를 쓸 수 있다', v_nick, v_id);
end;
$$;

-- 관리자 지정: 남의 후기를 "삭제만" 할 수 있다 (수정은 불가 — 확정된 규칙).
create or replace function admin.grant_admin(p_key text)
returns text
language plpgsql
as $$
declare v_id uuid; v_nick text;
begin
  v_id := admin.resolve_member(p_key);
  update public.profiles set is_admin = true where id = v_id
    returning coalesce(nickname, '(닉네임 없음)') into v_nick;
  return format('관리자 지정 — %s (%s) · 남의 후기 삭제 가능(수정은 불가)', v_nick, v_id);
end;
$$;

create or replace function admin.revoke_admin(p_key text)
returns text
language plpgsql
as $$
declare v_id uuid; v_nick text;
begin
  v_id := admin.resolve_member(p_key);

  if not exists (select 1 from public.profiles where id = v_id and is_admin) then
    raise exception '이미 관리자가 아닙니다: %', p_key;
  end if;

  -- ★ 관리자가 0명이 되면 남의 후기를 아무도 지울 수 없고,
  --   002 의 "기존 후기를 관리자 소유로" 백필 기준도 사라진다.
  if (select count(*) from public.profiles where is_admin) <= 1 then
    raise exception '마지막 관리자는 해제할 수 없습니다. 다른 회원을 먼저 admin.grant_admin() 하세요.';
  end if;

  update public.profiles set is_admin = false where id = v_id
    returning coalesce(nickname, '(닉네임 없음)') into v_nick;
  return format('관리자 해제 — %s (%s)', v_nick, v_id);
end;
$$;

-- ── 6) 접근 차단 재확인 ─────────────────────────────────────
-- 함수는 생성 시 PUBLIC 에 EXECUTE 가 자동으로 붙으므로 반드시 회수한다.
-- (스키마 USAGE 가 이미 없어 호출은 불가하지만, 이중으로 막아둔다)
revoke execute on all functions in schema admin from public, anon, authenticated;
revoke all     on all tables    in schema admin from public, anon, authenticated;

commit;


-- ============================================================
-- 실행 직후 확인
-- ============================================================
select * from admin.members;
-- select * from admin.reviews;


-- ============================================================
-- 사용법 — SQL Editor 에 필요한 줄만 붙여넣고 Run
-- ============================================================
-- 가입자 목록 / 회원별 후기·사진 수
--   select * from admin.members;
--
-- 후기 목록 (문제 후기 찾기)
--   select * from admin.reviews;
--   select * from admin.reviews where author = '홍길동';
--
-- 문제 회원 차단 / 해제  (쓰기만 막힌다. 열람과 기존 후기는 유지)
--   select admin.block('홍길동');
--   select admin.unblock('홍길동');
--
-- 관리자 권한 부여 / 회수
--   select admin.grant_admin('라봉');
--   select admin.revoke_admin('라봉');
--
-- 동명이인이면 예외가 나면서 UUID 후보를 보여준다. 그 UUID 로 다시 호출:
--   select admin.block('a1b2c3d4-....');
--
-- 후기 삭제는 여기서 하지 말 것.
--   Storage 파일이 고아로 남는다. 앱에서 관리자 계정으로 로그인해 삭제한다.
--   (삭제 순서 Storage → photos → trips 는 앱이 지킨다)


-- ============================================================
-- 롤백 — 이 스크립트가 만든 것만 통째로 제거
-- ============================================================
-- public 쪽 테이블·정책을 전혀 건드리지 않으므로 이 한 줄이면 원상복구된다.
--   drop schema admin cascade;
