// 파일: supabase/functions/filter-message/index.ts
//
// 채팅 메시지가 들어가는 유일한 길.
//
// 원래는 "이 문장 보내도 되나요?"만 답하는 검사기였다. 그런데 판정과 저장이
// 갈라져 있으면 클라이언트가 판정을 건너뛰고 messages 에 바로 넣을 수 있다.
// 그래서 마이그레이션 011 에서 messages 의 직접 insert 를 막고, 이 함수가
// 거른 뒤 직접 넣도록 바꿨다. 필터를 지나지 않은 메시지는 이제 존재할 수 없다.
//
// 흐름
//   1. Authorization 헤더로 보낸 사람이 누구인지 확인한다 (여기만 사용자 권한)
//   2. banned_words 로 마스킹 / 차단을 판정한다
//   3. send_chat_message() 로 넣는다 (service_role 만 부를 수 있는 함수)
//
// 방 참여자인지·방이 열려 있는지·계정이 살아 있는지는 이 함수가 아니라
// send_chat_message() 가 본다. service_role 은 RLS 를 통과해 버리므로
// 검사를 DB 쪽에 두어야 다른 경로가 생겨도 같이 지켜진다.
//
// 요청  { room_id: uuid, content: string, message_id?: uuid }
// 응답  성공      { allowed: true, message: {...}, was_filtered: boolean }
//       금지어    { allowed: false, blocked: true, error: "..." }   (status 200)
//       그 외     { error: "..." }
//
//   금지어 차단을 200 으로 돌려주는 이유: 프론트의 readFunctionResult 는
//   2xx 가 아니면 서버 메시지를 버리고 일반 오류 문구로 바꾼다. 사용자에게
//   "부적절한 표현이 포함되어 있어요"를 그대로 보여주려면 200 이어야 한다.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

/** messages.content 의 스키마 제약과 같은 값 */
const CONTENT_MAX = 2000;

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

const adminClient = createClient(supabaseUrl, serviceRoleKey);

// ------------------------------------------------------------
// 금지어 목록 캐시
//
// 메시지 한 통마다 banned_words 를 통째로 읽으면 대화가 오갈수록 그대로
// 쿼리가 된다. 목록은 운영자가 가끔 고치는 값이라 잠깐 묵어도 문제가 없다.
// 인스턴스가 살아 있는 동안만 유지되고, 새 단어는 늦어도 60초 뒤에 걸린다.
// ------------------------------------------------------------
type BannedWord = { word: string; severity: number };

const CACHE_TTL_MS = 60_000;
let cachedWords: BannedWord[] | null = null;
let cachedAt = 0;

async function loadBannedWords(): Promise<BannedWord[]> {
  const now = Date.now();
  if (cachedWords && now - cachedAt < CACHE_TTL_MS) return cachedWords;

  const { data, error } = await adminClient
    .from("banned_words")
    .select("word, severity");

  if (error) {
    // 목록을 못 읽었다고 대화를 막지는 않는다. 다만 묵은 목록이라도 있으면
    // 그걸 쓰고, 아예 없으면 이번 한 통은 거르지 못한 채 지나간다.
    console.error("[filter-message] banned_words 조회 실패", error);
    return cachedWords ?? [];
  }

  cachedWords = data ?? [];
  cachedAt = now;
  return cachedWords;
}

/**
 * severity
 *   1  마스킹해서 보낸다
 *   2+ 보내지 않는다
 */
function applyFilter(content: string, words: BannedWord[]) {
  let masked = content;
  let maxSeverity = 0;
  const hits: string[] = [];

  for (const { word, severity } of words) {
    if (!word || !masked.includes(word)) continue;
    maxSeverity = Math.max(maxSeverity, severity);
    hits.push(word);
    masked = masked.split(word).join("*".repeat(word.length));
  }

  return { masked, maxSeverity, hits };
}

Deno.serve(async (req) => {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return json({ error: "로그인이 필요해요" }, 401);
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData.user) {
    return json({ error: "인증 실패" }, 401);
  }

  const body = await req.json().catch(() => null);
  if (!body || typeof body !== "object") {
    return json({ error: "잘못된 요청이에요" }, 400);
  }

  const { room_id, content, message_id } = body as Record<string, unknown>;

  if (typeof room_id !== "string" || !UUID_RE.test(room_id)) {
    return json({ error: "채팅방을 찾을 수 없어요" }, 400);
  }
  if (typeof content !== "string" || content.trim().length === 0) {
    return json({ error: "내용이 비어있어요" }, 400);
  }
  if (content.length > CONTENT_MAX) {
    return json({ error: `메시지는 ${CONTENT_MAX}자까지 보낼 수 있어요` }, 400);
  }
  if (
    message_id !== undefined &&
    (typeof message_id !== "string" || !UUID_RE.test(message_id))
  ) {
    return json({ error: "잘못된 요청이에요" }, 400);
  }

  const { masked, maxSeverity, hits } = applyFilter(
    content,
    await loadBannedWords(),
  );

  if (maxSeverity >= 2) {
    return json({
      allowed: false,
      blocked: true,
      error: "부적절한 표현이 포함되어 있어요",
    });
  }

  const wasFiltered = maxSeverity > 0;

  // send_chat_message 는 setof 가 아니라 messages 한 줄을 돌려주므로
  // PostgREST 응답도 객체 하나다. .single() 을 덧붙일 필요가 없다.
  const { data: inserted, error: insertErr } = await adminClient.rpc(
    "send_chat_message",
    {
      p_room_id: room_id,
      p_sender_id: userData.user.id,
      p_content: masked,
      p_is_filtered: wasFiltered,
      // 어떤 단어가 걸렸는지 남긴다. 신고 처리할 때 원문 없이도 판단이 된다.
      p_filter_note: wasFiltered ? `금지어: ${hits.join(", ")}` : null,
      p_message_id: message_id ?? null,
    },
  );

  if (insertErr) {
    // send_chat_message() 가 던지는 문구는 그대로 보여줘도 되는 것들이다
    // ('이미 종료된 채팅방입니다' 등). 예상 밖의 오류만 감춘다.
    console.error("[filter-message] send_chat_message 실패", insertErr);
    const known = insertErr.code === "23514" || insertErr.code === "23505";
    return json(
      { error: known ? insertErr.message : "메시지를 보내지 못했어요" },
      known ? 200 : 500,
    );
  }

  return json({ allowed: true, message: inserted, was_filtered: wasFiltered });
});
