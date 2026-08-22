import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve(async (req) => {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return new Response(JSON.stringify({ error: "로그인이 필요해요" }), { status: 401 });
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData.user) {
    return new Response(JSON.stringify({ error: "인증 실패" }), { status: 401 });
  }

  const { content } = await req.json();
  if (typeof content !== "string" || content.trim().length === 0) {
    return new Response(JSON.stringify({ error: "내용이 비어있어요" }), { status: 400 });
  }

  const adminClient = createClient(supabaseUrl, serviceRoleKey);
  const { data: bannedWords } = await adminClient
    .from("banned_words")
    .select("word, severity");

  let masked = content;
  let maxSeverity = 0;
  for (const { word, severity } of bannedWords ?? []) {
    if (masked.includes(word)) {
      maxSeverity = Math.max(maxSeverity, severity);
      masked = masked.split(word).join("*".repeat(word.length));
    }
  }

  if (maxSeverity >= 2) {
    return new Response(
      JSON.stringify({ allowed: false, reason: "부적절한 표현이 포함되어 있어요" }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  }

  return new Response(
    JSON.stringify({ allowed: true, content: masked, was_filtered: maxSeverity > 0 }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
});