// Ra-Review 서비스워커 — '홈 화면에 추가'를 위한 최소 구성
//
// 크롬은 fetch 핸들러가 있는 서비스워커가 있어야 설치 프롬프트(beforeinstallprompt)를 띄운다.
// 그래서 존재 이유는 '설치 가능하게 만들기'이고, 캐싱은 최소한만 한다.
//
// ⚠️ 이 앱은 index.html 한 파일을 자주 고쳐 GitHub Pages로 올린다.
//    캐시가 최신 배포를 가리면 "커밋했는데 폰에서 옛날 화면"이 되므로
//    전략은 network-first 고정 — 캐시는 오프라인일 때만 쓴다.
//
// ⚠️ 서비스워커는 한번 배포하면 사용자 기기에 남는다. 없애려면
//    registration.unregister()를 호출하는 자폭 sw.js를 따로 배포해야 한다.

const CACHE = 'ra-review-v1';
const SHELL = './';

self.addEventListener('install', (e) => {
  // 새 워커를 대기시키지 않고 바로 활성화 → 항상 최신 코드가 돈다
  e.waitUntil(caches.open(CACHE).then((c) => c.add(SHELL)).catch(() => {}));
  self.skipWaiting();
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;

  // 페이지 이동만 우리가 관여한다.
  // Supabase API·사진(Storage)·CDN 스크립트는 손대지 않고 그대로 통과 —
  // 가로채면 후기 목록이 옛 데이터로 굳을 수 있다.
  if (req.mode !== 'navigate') return;

  e.respondWith(
    fetch(req)
      .then((res) => {
        // 온라인이면 항상 네트워크 응답을 쓰고, 오프라인 대비로만 갱신해 둔다
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(SHELL, copy)).catch(() => {});
        return res;
      })
      .catch(() => caches.match(SHELL, { ignoreSearch: true }))
  );
});
