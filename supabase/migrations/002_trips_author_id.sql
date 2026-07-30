-- ============================================================
-- 라봉후기 Script B-1 — trips.author_id + 기존 후기 백필 + 소유자 판정 헬퍼
-- (ROADMAP 카카오 로그인 2단계의 앞부분. RLS는 아직 켜지 않는다)
--
-- 선행 조건: 001_profiles.sql 실행 + profiles.is_admin = true 인 회원 1명 지정
-- 실행 후: index.html 을 배포하고 새 후기가 author_id 와 함께 저장되는지 확인
--          → 그 다음에 003 을 실행한다
--
-- 이 스크립트는 RLS를 켜지 않으므로 앱은 기존과 똑같이 동작한다.
-- ============================================================

begin;

-- ── 0) 안전 가드 ────────────────────────────────────────────
-- 관리자 미지정 상태로 실행하면 기존 후기의 author_id 가 NULL 로 남아
-- 아무도(관리자조차) 손댈 수 없게 된다.
do $$
begin
  if (select count(*) from public.profiles where is_admin) < 1 then
    raise exception '먼저 profiles.is_admin = true 를 1명 지정하세요. (001_profiles.sql 하단 참고)';
  end if;
end $$;

-- ── 1) author_id 컬럼 ───────────────────────────────────────
-- · nullable 유지: 회원 탈퇴 시 후기를 함께 날리지 않는다(cascade 금지).
--   NULL author 는 정책상 "본인 아님"이 되어 관리자만 삭제 가능 → 안전.
--   (null = uuid 는 NULL 로 평가되어 정책이 자연히 거부한다)
-- · default auth.uid(): 클라이언트가 author_id 를 빼먹어도 서버가 채우는 이중 안전장치.
alter table public.trips
  add column if not exists author_id uuid references auth.users(id) on delete set null;

alter table public.trips
  alter column author_id set default auth.uid();

create index if not exists trips_author_id_idx on public.trips(author_id);

comment on column public.trips.author_id is '후기 작성자. NULL이면 소유자 없음(관리자만 삭제 가능).';

-- ── 2) 기존 후기를 관리자 소유로 백필 ───────────────────────
update public.trips
   set author_id = (select id from public.profiles where is_admin order by created_at limit 1)
 where author_id is null;

-- ── 3) 소유자 판정 헬퍼 ─────────────────────────────────────
-- ★ 이 함수들은 trips.author_id 를 참조하므로 반드시 컬럼 추가 후에 만들어야 한다.
--   language sql 함수는 생성 시점에 본문이 검증되기 때문에
--   001(profiles)에 넣으면 "column author_id does not exist" 로 실패한다.

-- photos 정책에서 부모 trips 의 소유자를 판정
create or replace function public.trip_author(p_trip_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select t.author_id from public.trips t where t.id = p_trip_id;
$$;

-- Storage 경로({trip_id}/{filename})에서 후기 소유자를 판정
-- ★ (storage.foldername(name))[1]::uuid 캐스팅을 절대 쓰지 말 것:
--   uuid 가 아닌 폴더명이 하나만 있어도 정책 평가 중 22P02 에러가 난다.
--   id::text 로 비교하면 예외 없이 그냥 NULL(=거부)이 된다.
create or replace function public.storage_trip_owner(p_name text)
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select t.author_id
  from public.trips t
  where t.id::text = (storage.foldername(p_name))[1];
$$;

grant execute on function public.trip_author(uuid), public.storage_trip_owner(text)
  to anon, authenticated;

commit;

-- ── 확인 ────────────────────────────────────────────────────
select count(*) as null_author from public.trips where author_id is null;  -- 0 이어야 함

select id, caption, author_id, created_at
from public.trips order by created_at desc limit 5;
