import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};

const wheelbaseApiKey = Deno.env.get("WHEELBASE_API_KEY") || Deno.env.get("API_KEY") || "";
const availabilityEndpoint = "https://api.outdoorsy.com/v0/availability";
const rentalEndpoint = "https://api.outdoorsy.com/v0/rentals";
const authStrategies = [
  { name: "API-Token", headers: (key: string) => ({ "API-Token": key }) },
  { name: "Authorization Bearer", headers: (key: string) => ({ Authorization: `Bearer ${key}` }) },
  { name: "Authorization Token", headers: (key: string) => ({ Authorization: `Token ${key}` }) },
  { name: "X-API-Key", headers: (key: string) => ({ "X-API-Key": key }) },
];

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function isDate(value: string) {
  return /^\d{4}-\d{2}-\d{2}$/.test(value);
}

function firstBoolean(value: unknown): boolean | null {
  if (!value || typeof value !== "object") return null;

  if (Array.isArray(value)) {
    if (value.length === 0) return true;
    if (value.every((item) => item && typeof item === "object" && ("from" in item || "to" in item || "next_available" in item))) {
      return false;
    }

    const booleans = value.map(firstBoolean).filter((item): item is boolean => typeof item === "boolean");
    return booleans.length ? booleans.every(Boolean) : null;
  }

  const record = value as Record<string, unknown>;
  const direct = [
    record.available,
    record.is_available,
    record.isAvailable,
    record.available_for_period,
    record.currently_available,
  ];

  for (const candidate of direct) {
    if (typeof candidate === "boolean") return candidate;
  }

  if (typeof record.unavailable === "boolean") return !record.unavailable;

  for (const nested of Object.values(record)) {
    if (Array.isArray(nested)) {
      if (nested.length === 0) return true;
      const booleans = nested.map(firstBoolean).filter((item): item is boolean => typeof item === "boolean");
      if (booleans.length) return booleans.every(Boolean);
    } else if (nested && typeof nested === "object") {
      const result = firstBoolean(nested);
      if (typeof result === "boolean") return result;
    }
  }

  return null;
}

function dailyRateFromRental(value: unknown): number | null {
  if (!value || typeof value !== "object") return null;

  const record = value as Record<string, unknown>;
  const activePrice = record.active_price && typeof record.active_price === "object"
    ? (record.active_price as Record<string, unknown>)
    : {};
  const price = record.price && typeof record.price === "object"
    ? (record.price as Record<string, unknown>)
    : {};

  const centsCandidates = [
    activePrice.day,
    price.day,
    record.price_per_day,
    record.daily_rate_cents,
    record.day_price,
    record.original_day_price,
    record.calculated_day_price,
  ];

  for (const candidate of centsCandidates) {
    const amount = Number(candidate);
    if (amount > 1000) return amount / 100;
  }

  const dollarCandidates = [
    record.daily_rate,
    record.base_price,
    record.rate,
    price.daily,
    activePrice.daily,
  ];

  for (const candidate of dollarCandidates) {
    const amount = Number(candidate);
    if (amount > 0) return amount;
  }

  return null;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "GET") {
    return json({ error: "Method not allowed." }, 405);
  }

  if (!wheelbaseApiKey) {
    return json({ error: "Wheelbase API key is missing from Edge Function secrets." }, 500);
  }

  const url = new URL(request.url);
  const rentalId = url.searchParams.get("rental_id") || "";
  const from = url.searchParams.get("from") || "";
  const to = url.searchParams.get("to") || "";
  const fromTime = url.searchParams.get("from_time") || "";
  const toTime = url.searchParams.get("to_time") || "";
  const shouldIncludePrice = ["1", "true", "yes"].includes((url.searchParams.get("include_price") || "").toLowerCase());

  if (!/^\d+$/.test(rentalId)) {
    return json({ error: "A numeric rental_id is required." }, 400);
  }

  if (!isDate(from) || !isDate(to)) {
    return json({ error: "from and to dates must use YYYY-MM-DD." }, 400);
  }

  const upstreamUrl = new URL(availabilityEndpoint);
  upstreamUrl.searchParams.set("rental_id", rentalId);
  upstreamUrl.searchParams.set("from", from);
  upstreamUrl.searchParams.set("to", to);
  if (/^\d+$/.test(fromTime)) upstreamUrl.searchParams.set("from_time", fromTime);
  if (/^\d+$/.test(toTime)) upstreamUrl.searchParams.set("to_time", toTime);

  try {
    let lastErrorPayload: unknown = {};
    let lastStatus = 0;

    for (const strategy of authStrategies) {
      const response = await fetch(upstreamUrl, {
        headers: {
          Accept: "application/json",
          ...strategy.headers(wheelbaseApiKey),
        },
      });
      const text = await response.text();
      let payload: unknown = {};

      try {
        payload = text ? JSON.parse(text) : {};
      } catch {
        payload = { raw: text };
      }

      if (!response.ok) {
        lastStatus = response.status;
        lastErrorPayload = payload;
        if (response.status === 401 || response.status === 403) continue;

        return json({
          error: "Wheelbase availability request failed.",
          rentalId,
          status: response.status,
          authStrategy: strategy.name,
          payload,
        }, 502);
      }

      let dailyRate: number | null = null;
      let rentalPayload: unknown = null;

      if (shouldIncludePrice) {
        const rentalUrl = new URL(`${rentalEndpoint}/${rentalId}`);
        const rentalResponse = await fetch(rentalUrl, {
          headers: {
            Accept: "application/json",
            ...strategy.headers(wheelbaseApiKey),
          },
        });
        const rentalText = await rentalResponse.text();

        try {
          rentalPayload = rentalText ? JSON.parse(rentalText) : {};
        } catch {
          rentalPayload = { raw: rentalText };
        }

        if (rentalResponse.ok) {
          dailyRate = dailyRateFromRental(rentalPayload);
        }
      }

      return json({
        rentalId,
        from,
        to,
        authStrategy: strategy.name,
        available: firstBoolean(payload),
        dailyRate,
        payload,
        ...(shouldIncludePrice ? { rental: rentalPayload } : {}),
      });
    }

    return json({
      error: "Wheelbase availability request failed with every supported auth header.",
      rentalId,
      status: lastStatus,
      payload: lastErrorPayload,
    }, 502);
  } catch (error) {
    return json({
      error: error instanceof Error ? error.message : "Wheelbase availability request failed.",
      rentalId,
    }, 502);
  }
});
