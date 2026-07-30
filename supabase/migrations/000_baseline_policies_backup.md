# RLS 적용 전 기존 정책 백업 (2026-07-30)

001~003 마이그레이션을 실행하기 **직전**에 캡처한 상태.
롤백할 때 이 정책들을 그대로 다시 만들면 원래 상태로 돌아간다.

## 캡처한 쿼리

```sql
select schemaname, tablename, policyname, cmd, roles, qual, with_check
from pg_policies
where (schemaname='public' and tablename in ('trips','photos'))
   or (schemaname='storage' and tablename='objects')
order by schemaname, tablename, policyname;
```

## 결과 (6행)

| schemaname | tablename | policyname | cmd | roles | qual | with_check |
|---|---|---|---|---|---|---|
| public | photos | public access | ALL | {public} | true | true |
| public | trips | public access | ALL | {public} | true | true |
| storage | objects | public delete | DELETE | {public} | (bucket_id = 'trip-photos'::text) | NULL |
| storage | objects | public insert | INSERT | {public} | NULL | (bucket_id = 'trip-photos'::text) |
| storage | objects | public read | SELECT | {public} | (bucket_id = 'trip-photos'::text) | NULL |
| storage | objects | public update | UPDATE | {public} | (bucket_id = 'trip-photos'::text) | NULL |

### 읽는 법
- `trips`/`photos` 는 `FOR ALL` + `using(true)` + `with check(true)` → **누구나 읽기·쓰기·수정·삭제 전부 허용**. 지금 "아무나 남의 후기를 지울 수 있는" 상태의 원인이 이것.
- storage 4개는 전부 조건이 `bucket_id = 'trip-photos'` 뿐 → **버킷만 맞으면 누구나 업로드·삭제 가능**.
- 6개 모두 `qual`/`with_check` 에 `trip-photos` 또는 `true` 가 들어 있어, `003_rls_policies.sql` 의 정리 DO 블록이 전부 잡아서 삭제한다. (storage 쪽은 `%trip-photos%` 로 매칭 — 4개 모두 해당됨을 확인)

## 원상 복구용 SQL

`003` 을 실행한 뒤 완전히 되돌리고 싶을 때 사용.
먼저 003이 만든 정책들을 지우고 아래를 실행한다.

```sql
begin;

-- 003이 만든 정책 제거
do $$ declare r record; begin
  for r in select policyname, tablename from pg_policies
           where schemaname='public' and tablename in ('trips','photos')
  loop execute format('drop policy %I on public.%I', r.policyname, r.tablename); end loop;
end $$;
drop policy if exists tripphotos_read_public          on storage.objects;
drop policy if exists tripphotos_insert_own           on storage.objects;
drop policy if exists tripphotos_delete_own_or_admin  on storage.objects;

-- 원래 정책 재생성
create policy "public access" on public.photos for all to public using (true) with check (true);
create policy "public access" on public.trips  for all to public using (true) with check (true);

create policy "public delete" on storage.objects for delete to public using      (bucket_id = 'trip-photos'::text);
create policy "public insert" on storage.objects for insert to public with check (bucket_id = 'trip-photos'::text);
create policy "public read"   on storage.objects for select to public using      (bucket_id = 'trip-photos'::text);
create policy "public update" on storage.objects for update to public using      (bucket_id = 'trip-photos'::text);

commit;
```

> 급할 때는 이것 대신 `003_rls_policies.sql` 맨 아래의 "즉시 되돌리기"(RLS만 끄기)를 쓰는 게 더 빠르다.
