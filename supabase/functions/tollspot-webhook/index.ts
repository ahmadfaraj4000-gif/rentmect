import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const webhookToken = Deno.env.get("TOLLSPOT_WEBHOOK_TOKEN") || "";
const maxPayloadBytes = 1024 * 1024;
const adminClient = supabaseUrl && serviceRoleKey
  ? createClient(supabaseUrl, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } })
  : null;

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function safeEqual(left: string, right: string) {
  const encoder = new TextEncoder();
  const a = encoder.encode(left);
  const b = encoder.encode(right);
  let difference = a.length ^ b.length;
  const length = Math.max(a.length, b.length);
  for (let index = 0; index < length; index += 1) {
    difference |= (a[index] || 0) ^ (b[index] || 0);
  }
  return difference === 0;
}

function suppliedToken(req: Request) {
  const authorization = req.headers.get("authorization") || "";
  const bearer = authorization.match(/^Bearer\s+(.+)$/i)?.[1] || "";
  return req.headers.get("x-tollspot-token") || bearer;
}

async function sha256(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);
  if (!adminClient || !webhookToken) {
    console.error("TollSpot webhook is missing required server configuration.");
    return json({ error: "Integration is not configured." }, 503);
  }
  if (!safeEqual(suppliedToken(req), webhookToken)) return json({ error: "Unauthorized." }, 401);

  const declaredLength = Number(req.headers.get("content-length") || 0);
  if (declaredLength > maxPayloadBytes) return json({ error: "Payload is too large." }, 413);
  const raw = await req.text();
  if (new TextEncoder().encode(raw).byteLength > maxPayloadBytes) return json({ error: "Payload is too large." }, 413);

  let payload: unknown;
  try {
    payload = JSON.parse(raw);
  } catch {
    return json({ error: "A valid JSON payload is required." }, 400);
  }
  if (!payload || typeof payload !== "object") return json({ error: "A JSON object or array is required." }, 400);

  const payloadHash = await sha256(raw);
  const objectPayload = !Array.isArray(payload) ? payload as Record<string, unknown> : {};
  const providerEventId = String(
    req.headers.get("x-tollspot-event-id") ||
    req.headers.get("x-webhook-id") ||
    objectPayload.event_id ||
    objectPayload.eventId ||
    objectPayload.id ||
    "",
  ).trim();
  const eventKey = providerEventId ? `provider:${providerEventId}` : `sha256:${payloadHash}`;
  const eventType = String(objectPayload.event_type || objectPayload.eventType || objectPayload.type || "").trim() || null;

  const { data, error } = await adminClient
    .from("tollspot_webhook_events")
    .upsert({
      event_key: eventKey,
      provider_event_id: providerEventId || null,
      event_type: eventType,
      payload_sha256: payloadHash,
      payload,
      request_metadata: {
        content_type: req.headers.get("content-type"),
        user_agent: req.headers.get("user-agent"),
        tollspot_event_id: req.headers.get("x-tollspot-event-id"),
      },
      authentication_method: "shared_secret",
      status: "received",
    }, { onConflict: "event_key", ignoreDuplicates: true })
    .select("id")
    .maybeSingle();

  if (error) {
    console.error("TollSpot event intake failed", error);
    return json({ error: "Event could not be accepted." }, 500);
  }
  return json({ accepted: true, duplicate: !data?.id }, 202);
});
