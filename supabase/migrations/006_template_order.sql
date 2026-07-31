-- ============================================================
-- 라봉후기 Script E — 기본 후기 순서 바꾸기
-- (ROADMAP "기본 후기 3개 내용 채우기" 보조 도구)
--
-- 선행 조건: 005 실행 완료
-- 실행: Supabase 대시보드 > SQL Editor 에 전체 붙여넣고 Run
--
-- 피드는 최신순이라 기본 후기의 순서는 created_at 이 정한다.
-- 그런데 앱에는 작성 시각을 바꾸는 화면이 없다(있으면 안 된다).
-- 첫인상을 다듬는 동안 순서를 여러 번 바꾸게 되므로, 시각을 손으로 계산하지 않도록
-- "원하는 순서대로 제목만 나열하면 되는" 함수를 만든다.
--
-- 제목·사진·글 수정은 앱에서 하면 된다. 이 파일은 순서 전용이다.
-- ============================================================

begin;

-- ── 1) 템플릿 안에서만 후기 찾기 ────────────────────────────
-- 004 의 admin.resolve_trip() 은 전체 후기를 뒤지기 때문에 '테스트' 같은 짧은 말로 찾으면
-- "슈퍼베이스 테스트", "세로본능 테스트" 까지 걸려서 매번 예외가 난다.
-- 여기서는 템플릿 3개 안에서만 찾으므로 짧게 불러도 된다.
create or replace function admin.resolve_template(p_key text)
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
    raise exception '후기 제목(일부만 써도 됨) 또는 UUID를 입력하세요.';
  end if;

  -- UUID 를 그대로 넣은 경우
  if p_key ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select t.id into v_id from public.trips t where t.id = p_key::uuid and t.is_template;
    if v_id is null then
      raise exception '그런 템플릿이 없습니다: %', p_key;
    end if;
    return v_id;
  end if;

  -- ① 제목이 정확히 일치하는 것 먼저
  select count(*) into v_cnt from public.trips t where t.is_template and t.caption = p_key;
  if v_cnt = 1 then
    select t.id into v_id from public.trips t where t.is_template and t.caption = p_key;
    return v_id;
  end if;

  -- ② 없으면 제목에 포함된 것으로 (짧게 불러도 되게)
  select count(*) into v_cnt from public.trips t where t.is_template and t.caption ilike '%' || p_key || '%';

  if v_cnt = 0 then
    raise exception '제목에 "%" 가 들어간 템플릿이 없습니다. select * from admin.reviews where is_template; 로 확인하세요.', p_key;
  elsif v_cnt > 1 then
    select string_agg(format('%s  (%s)', t.id, t.caption), E'\n')
      into v_list
      from public.trips t where t.is_template and t.caption ilike '%' || p_key || '%';
    raise exception '"%" 로는 템플릿 %개가 걸립니다. 더 길게 쓰거나 UUID로 부르세요.', p_key, v_cnt
      using hint = v_list;
  end if;

  select t.id into v_id from public.trips t where t.is_template and t.caption ilike '%' || p_key || '%';
  return v_id;
end;
$$;

-- ── 2) 순서 바꾸기 ──────────────────────────────────────────
-- 사용법: 피드에 보이길 원하는 순서대로 나열한다 (첫 번째 = 맨 위)
--   select admin.order_templates('테스트', '설명서', '라리뷰');
--
-- ★ 기존 템플릿들이 쓰던 시각대를 그대로 두고 "순서만" 다시 매긴다.
--   now() 로 밀어버리면 관리자 본인 피드에서 이 3개가 맨 위로 튀어올라온다.
create or replace function admin.order_templates(variadic p_keys text[])
returns text
language plpgsql
as $$
declare
  v_total int;
  v_given int := coalesce(array_length(p_keys, 1), 0);
  v_base  timestamptz;
  v_key   text;
  v_id    uuid;
  v_ids   uuid[] := '{}';
  v_i     int := 0;
  v_out   text := '';
begin
  select count(*), max(created_at) into v_total, v_base
  from public.trips where is_template;

  if v_total = 0 then
    raise exception '템플릿으로 지정된 후기가 없습니다. 먼저 admin.set_template() 을 쓰세요.';
  end if;

  -- 일부만 넘기면 나머지가 어디로 갈지 알 수 없다 → 전부 나열하게 한다
  if v_given <> v_total then
    raise exception '템플릿은 %개인데 %개만 넘기셨습니다. 원하는 순서대로 전부 나열하세요.', v_total, v_given;
  end if;

  foreach v_key in array p_keys loop
    v_id := admin.resolve_template(v_key);

    if v_id = any(v_ids) then
      raise exception '"%" 가 두 번 들어갔습니다. 서로 다른 후기 %개를 나열하세요.', v_key, v_total;
    end if;
    v_ids := v_ids || v_id;

    update public.trips
       set created_at = v_base - (v_i * interval '1 minute')
     where id = v_id;

    v_i := v_i + 1;
    v_out := v_out || format(E'%s. %s\n', v_i,
      (select coalesce(caption, '(제목 없음)') from public.trips where id = v_id));
  end loop;

  return format(E'순서 변경 완료 (위 → 아래)\n%s', v_out);
end;
$$;

revoke execute on all functions in schema admin from public, anon, authenticated;

commit;


-- ============================================================
-- 지금 바꾸기 — 테스트 → 설명서 → 라리뷰
-- ============================================================
select admin.order_templates('테스트', '설명서', '라리뷰');

-- 확인 (위에서부터 피드에 보이는 순서)
select caption, created_at
from public.trips
where is_template
order by created_at desc;


-- ============================================================
-- 사용법
-- ============================================================
-- 순서를 또 바꾸고 싶을 때 — 원하는 순서대로 나열하면 끝
--   select admin.order_templates('설명서', '테스트', '라리뷰');
--
-- 제목을 바꿨다면 바뀐 제목으로 부르면 된다. 일부만 써도 되고,
-- 애매하면 후보를 보여주며 예외가 난다(엉뚱한 후기를 건드리지 않는다).
--
-- 제목·사진·글 수정은 앱에서 하면 된다. 슈파베이스가 필요 없다.
-- is_template 표시는 후기의 id 에 붙어 있어서 제목을 바꿔도 유지된다.


-- ============================================================
-- 롤백
-- ============================================================
-- drop function if exists admin.order_templates(text[]);
-- drop function if exists admin.resolve_template(text);
-- ※ 이미 바뀐 created_at 은 되돌아가지 않는다. 순서를 다시 지정하면 된다.
