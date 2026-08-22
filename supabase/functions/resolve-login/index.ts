// Follow this setup guide to integrate the Deno language server with your editor:
// https://deno.land/manual/getting_started/setup_your_environment
// This enables autocomplete, go to definition, etc.

// Setup type definitions for built-in Supabase Runtime APIs
import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";

// This endpoint uses 'publishable' | 'secret' access, apiKey is required.
// Use publishable for Client-facing, key-validated endpoints
// Use secret for Server-to-server, internal calls

/**
 * login_id → email 해석.
 *
 * Supabase Auth 는 이메일로만 로그인/가입할 수 있는데, 화면은 아이디(login_id)를
 * 받는다. profiles.profiles_select RLS 정책이 `to authenticated` 로만 열려 있어
 * 로그인 전에는 클라이언트가 profiles 를 직접 조회할 수 없으므로, 이 함수가
 * ctx.supabaseAdmin(service role, RLS 우회)으로 대신 찾아 email 을 돌려준다.
 *
 * 없는 아이디도, 잘못된 요청도 전부 401 + { error } 로 응답한다. 계정 존재 여부를
 * 굳이 구분해 노출하지 않기 위함이다(frontend/api/client.ts 의 login/checkLoginId 참고).
 */
export default {
  fetch: withSupabase({ auth: ["publishable", "secret"] }, async (req, ctx) => {
    const { login_id } = await req.json().catch(() => ({}));
    const loginId = typeof login_id === "string" ? login_id.trim() : "";

    if (!loginId) {
      return Response.json({ error: "아이디를 입력해주세요." }, { status: 401 });
    }

    const { data } = await ctx.supabaseAdmin
      .from("profiles")
      .select("email")
      .eq("login_id", loginId)
      .maybeSingle();

    if (!data?.email) {
      return Response.json({ error: "존재하지 않는 아이디예요." }, { status: 401 });
    }

    return Response.json({ email: data.email });
  }),
};

/* To invoke locally:

  1. Run `supabase start` (see: https://supabase.com/docs/reference/cli/supabase-start)
  2. Make an HTTP request:

  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/resolve-login' \
    --header 'apiKey: sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH' \
    --data '{"name":"Functions"}'

*/
