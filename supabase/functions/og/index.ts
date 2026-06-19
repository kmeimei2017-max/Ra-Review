// 라봉후기 - 카톡/SNS 동적 미리보기(Open Graph) Edge Function
//
// 동작: 친구가 받은 링크(.../functions/v1/og?id=후기ID)를 카톡 크롤러가 열면
//       해당 후기의 대표 사진/제목으로 OG 태그를 만들어 응답하고,
//       실제 사람은 앱(?view=후기ID)으로 자동 이동시킨다.
//
// 배포: Supabase 대시보드 > Edge Functions > "og" 함수에 이 코드를 붙여넣고 Deploy.
//       반드시 "Verify JWT" 옵션을 끈 상태로 배포해야 한다(크롤러는 인증 헤더가 없음).

const SUPABASE_URL = "https://swiferlakcaeokzwlgyz.supabase.co";
const ANON_KEY = "sb_publishable_RI46PspBesxDg9_Yg4fNkw_gXAhV_NG";
const APP_URL = "https://kmeimei2017-max.github.io/Ra-Review/";
const DEFAULT_IMAGE = APP_URL + "og-image.png";
const DESCRIPTION = "후기를 공유합니다 🎣";

function esc(s: string): string {
  return (s || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const id = url.searchParams.get("id");
  const appLink = APP_URL + (id ? "?view=" + encodeURIComponent(id) : "");

  let title = "라봉 낚시 후기";
  let image = DEFAULT_IMAGE;

  if (id) {
    try {
      const res = await fetch(
        `${SUPABASE_URL}/rest/v1/trips?id=eq.${encodeURIComponent(id)}` +
          `&select=caption,thumb_url,photos(url,order_index)`,
        { headers: { apikey: ANON_KEY, Authorization: `Bearer ${ANON_KEY}` } },
      );
      const rows = await res.json();
      const trip = Array.isArray(rows) ? rows[0] : null;
      if (trip) {
        if (trip.caption) title = trip.caption;
        if (trip.thumb_url) {
          image = trip.thumb_url; // 사용자가 고른 대표 사진
        } else if (trip.photos && trip.photos.length) {
          // 대표 미지정 시 첫 사진(order_index 0)
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
<a href="${esc(appLink)}">라봉 낚시 후기 보러가기</a>
</body>
</html>`;

  return new Response(html, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "public, max-age=300",
    },
  });
});
