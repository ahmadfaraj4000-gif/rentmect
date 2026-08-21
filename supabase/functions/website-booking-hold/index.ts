import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.4";

const allowedOrigins = new Set([
  "https://rentmect.com",
  "https://www.rentmect.com",
  "https://login.rentmect.com",
]);

const localOriginPattern = /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const datePattern = /^\d{4}-\d{2}-\d{2}$/;
const timePattern = /^(0?[1-9]|1[0-2]):[0-5]\d\s+(AM|PM)$/i;
const maxBodyBytes = 4096;

function isAllowedOrigin(origin: string): boolean {
  return allowedOrigins.has(origin) || localOriginPattern.test(origin);
}

function responseHeaders(origin: string): HeadersInit {
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-rentme-device",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "600",
    "Cache-Control": "no-store",
    "Content-Type": "application/json; charset=utf-8",
    "Vary": "Origin",
    "X-Content-Type-Options": "nosniff",
  };
}

function jsonResponse(origin: string, status: number, body: Record<string, unknown>, extraHeaders: HeadersInit = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...responseHeaders(origin), ...extraHeaders },
  });
}

function clientAddress(request: Request): string {
  const cloudflareAddress = request.headers.get("cf-connecting-ip")?.trim();
  if (cloudflareAddress) return cloudflareAddress.slice(0, 128);

  const forwarded = request.headers.get("x-forwarded-for")
    ?.split(",")
    .map((part) => part.trim())
    .filter(Boolean);
  if (forwarded?.length) return forwarded[forwarded.length - 1].slice(0, 128);

  return request.headers.get("x-real-ip")?.trim().slice(0, 128) || "unknown";
}

async function hmacHex(secret: string, value: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(value));
  return Array.from(new Uint8Array(signature))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

Deno.serve(async (request) => {
  const origin = request.headers.get("origin") || "";
  if (!origin || !isAllowedOrigin(origin)) {
    return new Response(JSON.stringify({ message: "Origin is not allowed." }), {
      status: 403,
      headers: {
        "Cache-Control": "no-store",
        "Content-Type": "application/json; charset=utf-8",
        "X-Content-Type-Options": "nosniff",
      },
    });
  }

  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: responseHeaders(origin) });
  }

  if (request.method !== "POST") {
    return jsonResponse(origin, 405, { message: "Method not allowed." }, { Allow: "POST, OPTIONS" });
  }

  const contentLength = Number(request.headers.get("content-length") || 0);
  if (contentLength > maxBodyBytes) {
    return jsonResponse(origin, 413, { message: "The checkout request is too large." });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  if (!supabaseUrl || !serviceRoleKey) {
    console.error("website-booking-hold is missing required Supabase environment variables");
    return jsonResponse(origin, 503, { message: "Secure checkout is temporarily unavailable. Please retry." });
  }

  const browserKey = request.headers.get("apikey")?.trim() || "";
  if (browserKey.length < 20 || browserKey.length > 2048) {
    return jsonResponse(origin, 401, { message: "The checkout request could not be authenticated." });
  }

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return jsonResponse(origin, 400, { message: "The checkout request is invalid." });
  }

  const pickupDate = String(body.pickup_date || "");
  const returnDate = String(body.return_date || "");
  const pickupTime = String(body.pickup_time || "");
  const returnTime = String(body.return_time || "");
  const vehicleId = String(body.vehicle_id || "");
  const deviceId = request.headers.get("x-rentme-device")?.trim() || "";

  if (
    !datePattern.test(pickupDate)
    || !datePattern.test(returnDate)
    || !timePattern.test(pickupTime)
    || !timePattern.test(returnTime)
    || !uuidPattern.test(vehicleId)
    || !uuidPattern.test(deviceId)
  ) {
    return jsonResponse(origin, 400, { message: "Choose a valid vehicle, pickup time, and return time." });
  }

  const [ipHash, deviceHash] = await Promise.all([
    hmacHex(serviceRoleKey, `ip:${clientAddress(request)}`),
    hmacHex(serviceRoleKey, `device:${deviceId.toLowerCase()}`),
  ]);

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data, error } = await adminClient.rpc("create_rate_limited_website_booking_hold", {
    p_pickup_date: pickupDate,
    p_return_date: returnDate,
    p_pickup_time: pickupTime,
    p_return_time: returnTime,
    p_vehicle_id: vehicleId,
    p_ip_hash: ipHash,
    p_device_hash: deviceHash,
  });

  if (error) {
    console.error("Protected booking hold RPC failed", {
      code: error.code,
      message: error.message,
    });
    return jsonResponse(origin, 503, { message: "Secure checkout is temporarily unavailable. Please retry." });
  }

  const result = Array.isArray(data) ? data[0] : data;
  if (!result?.accepted) {
    if (result?.error_code === "rate_limited") {
      return jsonResponse(
        origin,
        429,
        { message: "Too many checkout holds were started. Please wait 15 minutes or contact Rent Me CT." },
        { "Retry-After": "900" },
      );
    }
    if (result?.error_code === "vehicle_unavailable") {
      return jsonResponse(origin, 409, { message: "That vehicle is no longer available for the selected time. Choose another vehicle or time." });
    }
    return jsonResponse(origin, 400, { message: "Choose a valid vehicle, pickup time, and return time." });
  }

  return jsonResponse(origin, 201, {
    booking_id: result.booking_id,
    abandon_token: result.abandon_token,
    expires_at: result.expires_at,
  });
});
