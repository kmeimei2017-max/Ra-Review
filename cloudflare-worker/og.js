// Ra-Review - 카톡/SNS 동적 미리보기(Open Graph) Cloudflare Worker
//
// 동작: 친구가 받은 링크(.../?id=공유토큰)를 카톡 크롤러가 열면
//       해당 후기의 대표 사진/제목으로 OG 태그를 만들어 응답하고,
//       실제 사람은 앱(?view=공유토큰)으로 자동 이동시킨다.
//
// 🚨 ?id= 에 실리는 값은 후기 id 가 아니라 share_token(32자 hex)이다.
//    (파라미터 이름은 기존 링크와 맞추려고 그대로 뒀다.)
//    id 는 알아내면 열리는 이름표라, 링크를 안 받은 사람도 볼 수 있었다.
//
// 🚨 조회는 trip_by_token RPC 로만 한다. trips 를 직접 REST 조회하던 예전 방식은
//    "anon SELECT 전체 공개"에 기대고 있었는데, 010_narrow_select.sql 이 그걸 좁혔다.
//    RPC 는 security definer 라 계속 동작한다. service_role 키는 쓰지 않는다.
//
// 배포: Cloudflare 대시보드 > Workers & Pages > 워커 코드에 이 내용을 붙여넣고 Deploy.
//       (Supabase Edge Function과 달리 Cloudflare는 text/html을 그대로 응답함)

const SUPABASE_URL = "https://swiferlakcaeokzwlgyz.supabase.co";
const ANON_KEY = "sb_publishable_RI46PspBesxDg9_Yg4fNkw_gXAhV_NG";
const APP_URL = "https://ra-review.com/";
const DEFAULT_IMAGE = APP_URL + "og-image.jpg";
const DESCRIPTION = "후기를 공유합니다 🎣";

function esc(s) {
  return (s || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const token = url.searchParams.get("id"); // 값은 share_token (이름만 예전 그대로)
    const appLink = APP_URL + (token ? "?view=" + encodeURIComponent(token) : "");

    let title = "Ra-Review 낚시 후기";
    let image = DEFAULT_IMAGE;

    if (token) {
      try {
        const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/trip_by_token`, {
          method: "POST",
          headers: {
            apikey: ANON_KEY,
            Authorization: `Bearer ${ANON_KEY}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({ p_token: token }),
        });
        // 함수는 후기 1건(jsonb) 또는 null 을 돌려준다 — 배열이 아니다
        const trip = await res.json();
        if (trip) {
          if (trip.caption) title = trip.caption;
          if (trip.thumb_url) {
            image = trip.thumb_url; // 사용자가 고른 대표 사진
          } else if (trip.photos && trip.photos.length) {
            const sorted = [...trip.photos].sort(
              (a, b) => (a.order_index ?? 0) - (b.order_index ?? 0),
            );
            image = sorted[0].url;
          }
        }
      } catch (_e) {
        // 조회 실패 시 기본값 사용
      }
    }

    const html = `<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta property="og:type" content="website">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(DESCRIPTION)}">
<meta property="og:image" content="${esc(image)}">
<meta property="og:url" content="${esc(appLink)}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${esc(title)}">
<meta name="twitter:description" content="${esc(DESCRIPTION)}">
<meta name="twitter:image" content="${esc(image)}">
<meta http-equiv="refresh" content="0; url=${esc(appLink)}">
<title>${esc(title)}</title>
</head>
<body>
<script>location.replace(${JSON.stringify(appLink)});</script>
<a href="${esc(appLink)}">Ra-Review 후기 보러가기</a>
</body>
</html>`;

    return new Response(html, {
      headers: {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "public, max-age=300",
      },
    });
  },
};
