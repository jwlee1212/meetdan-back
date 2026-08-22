import { Webhook } from "https://esm.sh/standardwebhooks@1.0.0";

// Supabase가 주는 훅 시크릿은 "v1,whsec_<base64>" 형태이고, Webhook에는 base64 본문만
// 넘겨야 한다. 접두어가 두 번 붙거나("v1,whsec_v1,whsec_...") 따옴표/공백이 섞여 저장되는
// 사고가 잦아서, 마지막 "whsec_" 뒤쪽만 취해 어떤 형태든 본문으로 정규화한다.
// (String.replace는 문자열 인자일 때 첫 한 번만 치환하므로 중복 접두어를 못 지운다.)
function normalizeHookSecret(raw: string): string {
  const unquoted = raw.trim().replace(/^["']|["']$/g, "").trim();
  const marker = "whsec_";
  const lastMarker = unquoted.lastIndexOf(marker);
  return lastMarker === -1 ? unquoted : unquoted.slice(lastMarker + marker.length);
}

const rawHookSecret = Deno.env.get("AUTH_HOOK_SECRET");
if (!rawHookSecret) {
  throw new Error("AUTH_HOOK_SECRET 시크릿이 설정되어 있지 않아요.");
}

const hookSecret = normalizeHookSecret(rawHookSecret);
if (!/^[A-Za-z0-9+/]+={0,2}$/.test(hookSecret)) {
  // 시크릿 값은 절대 로그에 남기지 않고, 길이 등 형태 정보만 노출한다.
  throw new Error(
    "AUTH_HOOK_SECRET 형식이 올바르지 않아요. 정규화 후에도 base64가 아닌 문자가 남아 있어요 " +
      `(원본 ${rawHookSecret.length}자, 정규화 후 ${hookSecret.length}자). ` +
      "대시보드 Auth > Hooks의 값을 v1,whsec_ 접두어까지 그대로, 한 번만 등록했는지 확인하세요.",
  );
}

const wh = new Webhook(hookSecret);

const ALLOWED_DOMAIN = "dankook.ac.kr";

// Auth 훅이 200이 아닌 상태를 돌려주면 메시지가 버려지고 500으로 바뀌므로,
// 가입 거부는 200 + error 페이로드로 알린다.
function rejectSignup(message: string) {
  return new Response(
    JSON.stringify({ error: { http_code: 400, message } }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

Deno.serve(async (req) => {
  const payload = await req.text();
  const headers = Object.fromEntries(req.headers);

  let data: { user?: { email?: string } };
  try {
    data = wh.verify(payload, headers) as { user?: { email?: string } };
  } catch {
    return new Response("invalid signature", { status: 401 });
  }

  const email = (data.user?.email ?? "").trim().toLowerCase();
  const atIndex = email.lastIndexOf("@");
  const domain = atIndex === -1 ? "" : email.slice(atIndex + 1);

  if (domain !== ALLOWED_DOMAIN) {
    return rejectSignup("단국대학교 이메일(@dankook.ac.kr)로만 가입할 수 있어요.");
  }

  return new Response(JSON.stringify({}), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
