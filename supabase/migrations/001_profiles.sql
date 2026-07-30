-- ============================================================
-- 라봉후기 Script A — profiles + 헬퍼 함수 + 카카오 프로필 자동 동기화
-- (ROADMAP 카카오 로그인 3단계. 2단계 RLS가 이 헬퍼를 참조하므로 먼저 실행)
--
-- 실행: Supabase 대시보드 > SQL Editor 에 전체 붙여넣고 Run
-- 이 스크립트는 RLS를 켜지 않으므로 앱 동작에 영향이 없다.
-- ============================================================

begin;

-- ── 1) profiles ─────────────────────────────────────────────
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  nickname    text,
  avatar_url  text,
  is_admin    boolean not null default false,
  is_blocked  boolean not null default false,
  created_at  timestamptz not null default now()
);

comment on table  public.profiles            is '카카오 로그인 회원. 닉네임/아바타는 트리거로 자동 동기화(앱에 수정 UI 없음).';
comment on column public.profiles.is_admin   is 'true면 남의 후기를 삭제만 가능(수정은 불가).';
comment on column public.profiles.is_blocked is 'true면 쓰기 전면 차단. 로그인·열람·기존 후기 노출은 유지.';

-- ── 2) profiles RLS : 본인 행만 읽기 ────────────────────────
-- 쓰기 정책은 아예 만들지 않는다 → 일반 사용자는 절대 못 쓴다.
-- 쓰는 주체는 아래 SECURITY DEFINER 트리거와 Studio(service_role)뿐.
alter table public.profiles enable row level security;

drop policy if exists profiles_select_self on public.profiles;
create policy profiles_select_self on public.profiles
  for select to authenticated
  using (id = auth.uid());

revoke insert, update, delete on public.profiles from anon, authenticated;
grant  select on public.profiles to authenticated;

-- ── 3) 헬퍼 함수 ────────────────────────────────────────────
-- ★ 무한 재귀 방지 (핵심):
--   profiles에 RLS가 걸려 있으므로, 다른 테이블의 정책이 profiles를 조회하면
--   정책 평가 안에서 정책이 다시 평가된다(재귀/권한 오류 위험).
--   security definer 함수는 소유자(테이블 소유자) 권한으로 실행되고
--   테이블 소유자는 RLS를 우회하므로 재평가가 일어나지 않는다.
-- ★ security definer 에는 반드시 set search_path 를 박는다 (함수 하이재킹 방지).
-- ★ 프로필 행이 없어도 안전 기본값(관리자 아님 / 차단 아님)이 되도록 coalesce.

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select p.is_admin from public.profiles p where p.id = auth.uid()), false);
$$;

create or replace function public.is_blocked()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select p.is_blocked from public.profiles p where p.id = auth.uid()), false);
$$;

grant execute on function public.is_admin(), public.is_blocked() to anon, authenticated;

-- ── 4) 카카오 닉네임/프로필사진 자동 동기화 트리거 ──────────
-- INSERT(첫 로그인) 뿐 아니라 UPDATE 도 처리한다.
--   Supabase(GoTrue)는 재로그인마다 provider가 준 값으로 raw_user_meta_data 를 갱신한다.
--   UPDATE를 안 다루면 카카오에서 닉네임/사진을 바꿔도 "첫 로그인 시점 값"이 영구 고정된다.
-- is_admin / is_blocked 는 절대 건드리지 않는다 (관리자가 준 값 보존).
-- 카카오가 값을 안 주면(null) 기존 값을 지우지 않는다 (coalesce).
-- coalesce 키 순서는 index.html 의 renderProfileButton() 과 일치시킨다.
create or replace function public.sync_profile_from_auth()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_nick   text;
  v_avatar text;
begin
  v_nick := nullif(btrim(coalesce(
      new.raw_user_meta_data->>'name',
      new.raw_user_meta_data->>'full_name',
      new.raw_user_meta_data->>'nickname',
      new.raw_user_meta_data->>'preferred_username'
  )), '');
  v_avatar := nullif(btrim(coalesce(
      new.raw_user_meta_data->>'avatar_url',
      new.raw_user_meta_data->>'picture'
  )), '');

  insert into public.profiles as p (id, nickname, avatar_url)
  values (new.id, v_nick, v_avatar)
  on conflict (id) do update
    set nickname   = coalesce(excluded.nickname,   p.nickname),
        avatar_url = coalesce(excluded.avatar_url, p.avatar_url);

  return new;
exception when others then
  -- ★ auth.users 트리거가 에러를 던지면 "로그인/회원가입 자체"가 실패한다.
  --   프로필은 부가 정보이고, 행이 없어도 정책은 안전 기본값으로 동작하므로
  --   여기서는 경고만 남기고 로그인을 통과시킨다.
  raise warning '[rabong] profile sync 실패 (uid=%): %', new.id, sqlerrm;
  return new;
end;
$$;

drop trigger if exists trg_sync_profile_ins on auth.users;
create trigger trg_sync_profile_ins
  after insert on auth.users
  for each row execute function public.sync_profile_from_auth();

drop trigger if exists trg_sync_profile_upd on auth.users;
create trigger trg_sync_profile_upd
  after update of raw_user_meta_data on auth.users
  for each row
  when (new.raw_user_meta_data is distinct from old.raw_user_meta_data)
  execute function public.sync_profile_from_auth();

-- ── 5) 이미 가입한 회원 백필 ────────────────────────────────
insert into public.profiles (id, nickname, avatar_url)
select u.id,
       nullif(btrim(coalesce(u.raw_user_meta_data->>'name',
                             u.raw_user_meta_data->>'full_name',
                             u.raw_user_meta_data->>'nickname',
                             u.raw_user_meta_data->>'preferred_username')), ''),
       nullif(btrim(coalesce(u.raw_user_meta_data->>'avatar_url',
                             u.raw_user_meta_data->>'picture')), '')
from auth.users u
on conflict (id) do nothing;

commit;

-- ── 확인 ────────────────────────────────────────────────────
-- 내 카카오 닉네임이 보이는 행의 id 를 복사해서 아래 "관리자 지정"에 쓴다.
select p.id, p.nickname, p.is_admin, p.is_blocked, u.created_at
from public.profiles p join auth.users u using (id)
order by u.created_at;


-- ============================================================
-- 다음 수동 단계 — 관리자 지정 (002 실행 전 필수)
-- ============================================================
-- update public.profiles set is_admin = true where id = '<내-UUID>';
--
-- 회원이 나 혼자라면:
-- update public.profiles set is_admin = true
--   where id = (select id from auth.users order by created_at limit 1);
--
-- 확인 (1행 나와야 함):
-- select id, nickname, is_admin from public.profiles where is_admin;
