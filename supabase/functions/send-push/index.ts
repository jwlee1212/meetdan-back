// 파일: supabase/functions/send-push/index.ts
//
// 알림 한 줄을 그 사람의 기기로 밀어 넣는다.
//
// 부르는 쪽은 사람이 아니라 DB다. notifications 에 행이 하나 생기면
// dispatch_push_notification 트리거(마이그레이션 013)가 pg_net 으로 이 함수를
// 부른다. 그래서 요청 본문에는 알림 id 하나만 들어 있다.
//
// 흐름
//   1. service_role 키로 온 요청인지 확인한다 (사람이 부를 수 없어야 한다)
//   2. 알림 한 줄과 그 사람의 기기 토큰을 읽는다
//   3. Expo Push API 로 보낸다 (한 번에 100개씩)
//   4. "이 기기는 이제 없다"는 응답이 온 토큰은 지운다
//
// 왜 내용을 받지 않고 id 만 받나
//   트리거가 문구를 실어 보내면 저장된 알림과 푸시에 뜬 문구가 어긋날 수
//   있다(누군가 중간에서 바꿔 부르면). id 만 받고 여기서 직접 읽으면
//   알림 센터에 남는 문구와 잠금화면에 뜨는 문구가 항상 같은 한 줄이다.
//
// 요청  { notification_id: uuid }
// 응답  { sent: number, removed: number }        보낸 기기 수 / 지운 토큰 수
//       { skipped: "..." }                        보낼 것이 없었다 (정상)
//       { error: "..." }
//
// ⚠️ 영수증(receipt)은 아직 확인하지 않는다.
//    Expo 는 접수증(ticket)을 바로 주고, 실제 배달 결과는 15분쯤 뒤에
//    영수증으로 알려준다. 그걸 보려면 ticket id 를 저장해 두고 나중에
//    다시 물어보는 두 번째 함수가 필요하다. 지금은 접수 단계에서 이미
//    드러나는 DeviceNotRegistered 만 처리한다 — 죽은 토큰의 대부분이
//    여기서 걸린다.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;

/**
 * 서버 열쇠.
 *
 * 이 프로젝트처럼 새 API 키 형식(sb_publishable_… / sb_secret_…)을 쓰는
 * 프로젝트와 예전 JWT 형식(service_role)을 쓰는 프로젝트가 섞여 있어서
 * 둘 다 받는다. 먼저 잡히는 값으로 DB에 붙고, 들어온 요청의 Authorization
 * 도 이 목록과 대조한다.
 *
 * ⚠️ Vault 의 service_role_key 에는 여기 있는 것과 '같은 값'을 넣어야 한다.
 *    Dashboard → Settings → API Keys 에서 secret(또는 service_role) 을
 *    그대로 복사하면 된다. 다른 값을 넣으면 아래 403 으로 막힌다.
 */
const serviceKeys = [
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
  Deno.env.get("SUPABASE_SECRET_KEY"),
].filter((key): key is string => !!key);

const serviceRoleKey = serviceKeys[0] ?? "";

const EXPO_PUSH_URL = "https://exp.host/--/api/v2/push/send";

/** Expo 가 한 번에 받는 최대 개수 */
const CHUNK_SIZE = 100;

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

const adminClient = createClient(supabaseUrl, serviceRoleKey);

type NotificationRow = {
  id: string;
  user_id: string;
  kind: string;
  title: string;
  body: string;
  team_id: string | null;
  match_id: string | null;
  room_id: string | null;
};

type ExpoMessage = {
  to: string;
  title: string;
  body: string;
  sound: "default";
  badge?: number;
  /** 앱이 알림을 눌렀을 때 어디로 갈지 정하는 데 쓴다 (utils/notifications.ts) */
  data: Record<string, string | null>;
  /** 안드로이드 채널. 앱에서 만든 이름과 같아야 소리가 난다 (lib/push.ts) */
  channelId: "default";
  priority: "high";
};

type ExpoTicket = {
  status: "ok" | "error";
  id?: string;
  message?: string;
  details?: { error?: string };
};

/**
 * 접수증을 보고 죽은 토큰을 지운다.
 *
 * DeviceNotRegistered = 앱을 지웠거나 알림을 껐다. 그대로 두면 이 사람에게
 * 알림이 갈 때마다 실패가 쌓이고, Expo 는 이런 토큰이 많은 프로젝트의
 * 발송을 제한한다. 응답에서 알게 된 순간 지우는 게 가장 확실하다.
 */
async function pruneDeadTokens(
  tokens: string[],
  tickets: ExpoTicket[],
): Promise<number> {
  const dead: string[] = [];

  tickets.forEach((ticket, i) => {
    if (ticket.status !== "error") return;

    // 접수증은 보낸 순서대로 온다. 순서가 어긋나면 엉뚱한 토큰을 지우게
    // 되므로, 길이가 맞지 않으면 아무것도 지우지 않는다.
    const token = tokens[i];
    if (!token) return;

    if (ticket.details?.error === "DeviceNotRegistered") {
      dead.push(token);
    } else {
      console.error("[send-push] 발송 실패", ticket.message, ticket.details);
    }
  });

  if (dead.length === 0) return 0;

  const { error } = await adminClient
    .from("push_tokens")
    .delete()
    .in("token", dead);

  if (error) {
    console.error("[send-push] 죽은 토큰 삭제 실패", error);
    return 0;
  }
  return dead.length;
}

Deno.serve(async (req) => {
  // 1. 부를 수 있는 것은 DB 트리거뿐이다.
  //
  //    게이트웨이의 JWT 검사에 기대지 않고 여기서 직접 본다. 그쪽은 켜 두어도
  //    '로그인한 사용자 아무나' 를 통과시키므로, 남의 알림 id 로 이 함수를
  //    두들겨 같은 푸시를 몇 번이고 보내게 할 수 있다. 서버 열쇠를 가진
  //    호출(= DB 트리거)만 지나가야 한다.
  //    (그래서 config.toml 에서 이 함수의 verify_jwt 는 꺼 두었다 —
  //     검사가 두 벌이면 새 키 형식에서 게이트웨이가 먼저 막을 수 있다)
  const auth = req.headers.get("Authorization") ?? "";
  const authorized = serviceKeys.some((key) => auth === `Bearer ${key}`);
  if (!authorized) {
    return json({ error: "forbidden" }, 403);
  }

  const body = await req.json().catch(() => null);
  const notificationId = (body as { notification_id?: unknown } | null)
    ?.notification_id;

  if (typeof notificationId !== "string" || !UUID_RE.test(notificationId)) {
    return json({ error: "notification_id 가 필요해요" }, 400);
  }

  // 2. 알림 한 줄
  const { data: notification, error: notiErr } = await adminClient
    .from("notifications")
    .select("id, user_id, kind, title, body, team_id, match_id, room_id")
    .eq("id", notificationId)
    .maybeSingle<NotificationRow>();

  if (notiErr) {
    console.error("[send-push] 알림 조회 실패", notiErr);
    return json({ error: "알림을 읽지 못했어요" }, 500);
  }
  if (!notification) {
    // 트리거가 부른 뒤 알림이 지워졌다(대상 팀 삭제 등). 정상 흐름이다.
    return json({ skipped: "알림이 없어요" });
  }

  // 3. 그 사람의 기기들
  const { data: tokenRows, error: tokenErr } = await adminClient
    .from("push_tokens")
    .select("token")
    .eq("user_id", notification.user_id);

  if (tokenErr) {
    console.error("[send-push] 토큰 조회 실패", tokenErr);
    return json({ error: "기기 목록을 읽지 못했어요" }, 500);
  }

  const tokens = (tokenRows ?? []).map((row) => row.token as string);
  if (tokens.length === 0) {
    return json({ skipped: "등록된 기기가 없어요" });
  }

  // 4. 앱 아이콘 뱃지 숫자 = 안 읽은 알림 개수.
  //    방금 만들어진 이 알림도 포함된다(아직 읽지 않았으므로).
  //    못 세도 발송은 계속한다 — 뱃지는 없어도 되는 값이다.
  const { count: unread } = await adminClient
    .from("notifications")
    .select("id", { count: "exact", head: true })
    .eq("user_id", notification.user_id)
    .is("read_at", null);

  const messages: ExpoMessage[] = tokens.map((token) => ({
    to: token,
    title: notification.title,
    body: notification.body,
    sound: "default",
    badge: unread ?? undefined,
    data: {
      notificationId: notification.id,
      kind: notification.kind,
      teamId: notification.team_id,
      matchId: notification.match_id,
      roomId: notification.room_id,
    },
    channelId: "default",
    priority: "high",
  }));

  let sent = 0;
  let removed = 0;

  for (let i = 0; i < messages.length; i += CHUNK_SIZE) {
    const chunk = messages.slice(i, i + CHUNK_SIZE);
    const chunkTokens = tokens.slice(i, i + CHUNK_SIZE);

    try {
      const response = await fetch(EXPO_PUSH_URL, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
        },
        body: JSON.stringify(chunk),
      });

      const result = await response.json().catch(() => null);

      if (!response.ok) {
        console.error("[send-push] Expo 응답 오류", response.status, result);
        continue;
      }

      const tickets: ExpoTicket[] = result?.data ?? [];
      sent += tickets.filter((t) => t.status === "ok").length;
      removed += await pruneDeadTokens(chunkTokens, tickets);
    } catch (e) {
      // 한 묶음이 실패해도 나머지는 보낸다.
      console.error("[send-push] Expo 호출 실패", e);
    }
  }

  return json({ sent, removed });
});
