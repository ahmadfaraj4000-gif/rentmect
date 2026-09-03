import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import {
  TollSpotApiError,
  TollSpotCharge,
  TollSpotClient,
  TollSpotLicensePlate,
  TollSpotPlateAssignment,
  TollSpotVehicle,
} from "../_shared/tollspot-client.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
  Deno.env.get("SERVICE_ROLE_KEY") || "";
const anonKey = Deno.env.get("SUPABASE_ANON_KEY") || "";
const tollspotApiKey = Deno.env.get("TOLLSPOT_API_KEY") || "";
const tollspotBaseUrl = Deno.env.get("TOLLSPOT_API_BASE_URL") || "";
const tollspotApiVersion = Deno.env.get("TOLLSPOT_API_VERSION") || "1.0.0";
const scheduledSyncSecret = Deno.env.get("TOLLSPOT_SYNC_SECRET") || "";

const adminClient = supabaseUrl && serviceRoleKey
  ? createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  })
  : null;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey, x-tollspot-sync-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type Action = "health" | "sync_fleet" | "sync_tolls" | "backfill_tolls" | "run_all" | "assign_transponder";

type LocalVehicle = {
  id: string;
  name: string;
  brand: string;
  model: string;
  vehicle_type: string;
  plate_number: string | null;
  vin: string | null;
  status: string | null;
  created_at: string;
  tollspot_enabled: boolean;
  tollspot_vehicle_type: string | null;
  plate_state: string | null;
  plate_country: string | null;
  plate_assigned_at: string | null;
  model_year: number | null;
};

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
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

function bearerToken(req: Request) {
  return (req.headers.get("authorization") || "").match(/^Bearer\s+(.+)$/i)?.[1] || "";
}

async function authorize(req: Request) {
  if (!adminClient) return { authorized: false, source: "none", userId: null };
  const suppliedScheduleSecret = req.headers.get("x-tollspot-sync-secret") || "";
  if (scheduledSyncSecret && safeEqual(suppliedScheduleSecret, scheduledSyncSecret)) {
    return { authorized: true, source: "schedule", userId: null };
  }
  if (suppliedScheduleSecret) {
    const { data: verifiedByDatabase, error: verificationError } = await adminClient
      .rpc("verify_tollspot_sync_secret", { p_secret: suppliedScheduleSecret });
    if (!verificationError && verifiedByDatabase === true) {
      return { authorized: true, source: "schedule", userId: null };
    }
  }
  const token = bearerToken(req);
  if (!token || !anonKey) return { authorized: false, source: "none", userId: null };
  const { data: userData, error: userError } = await adminClient.auth.getUser(token);
  if (userError || !userData.user) return { authorized: false, source: "none", userId: null };
  const { data: profile } = await adminClient
    .from("profiles")
    .select("role")
    .eq("id", userData.user.id)
    .maybeSingle();
  return {
    authorized: profile?.role === "admin",
    source: "admin",
    userId: profile?.role === "admin" ? userData.user.id : null,
  };
}

function client() {
  return new TollSpotClient({
    baseUrl: tollspotBaseUrl,
    apiKey: tollspotApiKey,
    apiVersion: tollspotApiVersion,
  });
}

function cleanText(value: unknown, maximum = 500) {
  const text = String(value ?? "").trim();
  return text ? text.slice(0, maximum) : null;
}

function cleanIdentifier(value: unknown) {
  const text = cleanText(value, 200);
  if (!text) throw new TollSpotApiError("TollSpot record is missing its identifier.", 0, "INVALID_PROVIDER_RECORD");
  return text;
}

function parseTimestamp(value: unknown, field: string, nullable = false) {
  if ((value === null || value === undefined || value === "") && nullable) return null;
  const date = new Date(String(value || ""));
  if (Number.isNaN(date.getTime())) {
    throw new TollSpotApiError(`TollSpot returned an invalid ${field}.`, 0, "INVALID_PROVIDER_RECORD");
  }
  return date.toISOString();
}

function formatApiDate(date: Date) {
  const month = String(date.getUTCMonth() + 1).padStart(2, "0");
  const day = String(date.getUTCDate()).padStart(2, "0");
  return `${month}/${day}/${date.getUTCFullYear()}`;
}

function parseRequestedDate(value: unknown, fallback: Date) {
  if (!value) return fallback;
  const match = String(value).match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!match) throw new Error("Dates must use YYYY-MM-DD.");
  const parsed = new Date(`${match[1]}-${match[2]}-${match[3]}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime())) throw new Error("A valid date is required.");
  return parsed;
}

async function defaultTollStartDate(action: Action, now: Date) {
  const maximumLookback = new Date(now);
  maximumLookback.setUTCDate(maximumLookback.getUTCDate() - 30);
  if (action === "backfill_tolls") return maximumLookback;

  const { data } = await adminClient!
    .from("tollspot_sync_runs")
    .select("to_date")
    .in("action", ["sync_tolls", "backfill_tolls", "run_all"])
    .in("status", ["succeeded", "partial"])
    .not("to_date", "is", null)
    .order("completed_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  const watermark = data?.to_date ? new Date(`${data.to_date}T00:00:00Z`) : new Date(now);
  if (Number.isNaN(watermark.getTime())) return maximumLookback;
  watermark.setUTCDate(watermark.getUTCDate() - 3);
  if (watermark < maximumLookback) return maximumLookback;
  return watermark > now ? now : watermark;
}

function providerVehicleStatus(localStatus: string | null) {
  const status = String(localStatus || "").toLowerCase();
  if (["reserved", "rented", "active", "on_the_road"].includes(status)) return "IN_USE";
  if (["maintenance", "unavailable"].includes(status)) return "OUT_OF_SERVICE";
  if (["inactive", "retired"].includes(status)) return "RETIRED";
  return "AVAILABLE";
}

function normalizedPlate(value: unknown) {
  return String(value || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
}

function normalizedTransponder(value: unknown) {
  return String(value || "").trim().replace(/[^A-Za-z0-9]/g, "");
}

function validateLocalVehicle(vehicle: LocalVehicle) {
  const missing: string[] = [];
  if (!cleanText(vehicle.brand, 50)) missing.push("brand");
  if (!cleanText(vehicle.model, 50)) missing.push("model");
  if (!vehicle.tollspot_vehicle_type) missing.push("TollSpot vehicle type");
  if (!normalizedPlate(vehicle.plate_number)) missing.push("plate number");
  if (!/^[A-Z]{2,3}$/.test(String(vehicle.plate_state || "").toUpperCase())) missing.push("plate state");
  if (!/^[A-Z]{2,3}$/.test(String(vehicle.plate_country || "").toUpperCase())) missing.push("plate country");
  if (!vehicle.plate_assigned_at) missing.push("plate effective time");
  const vin = String(vehicle.vin || "").toUpperCase().replace(/[^A-HJ-NPR-Z0-9]/g, "");
  if (vin && vin.length < 8) missing.push("VIN (minimum 8 characters)");
  if (!vin && !vehicle.model_year) missing.push("VIN or model year");
  if (missing.length) {
    throw new TollSpotApiError(
      `${vehicle.name || vehicle.id} is missing: ${missing.join(", ")}.`,
      0,
      "LOCAL_VEHICLE_INCOMPLETE",
    );
  }
  return { vin, plate: normalizedPlate(vehicle.plate_number) };
}

async function createRun(action: Action, source: string, userId: string | null, fromDate?: Date, toDate?: Date) {
  const { data, error } = await adminClient!.from("tollspot_sync_runs").insert({
    action,
    trigger_source: source,
    requested_by: userId,
    from_date: fromDate ? fromDate.toISOString().slice(0, 10) : null,
    to_date: toDate ? toDate.toISOString().slice(0, 10) : null,
  }).select("id").single();
  if (error) throw error;
  return data.id as string;
}

async function finishRun(runId: string, values: Record<string, unknown>) {
  await adminClient!.from("tollspot_sync_runs").update({
    ...values,
    completed_at: new Date().toISOString(),
  }).eq("id", runId);
}

async function failRun(runId: string | null, error: unknown) {
  if (!runId) return;
  const apiError = error instanceof TollSpotApiError ? error : null;
  await finishRun(runId, {
    status: "failed",
    error_code: apiError?.code || "SYNC_FAILED",
    error_message: cleanText(error instanceof Error ? error.message : "TollSpot sync failed.", 500),
  });
}

async function runHealth(api: TollSpotClient) {
  const response = await api.listVehicles();
  return {
    connected: true,
    apiVersion: api.configuration().apiVersion,
    origin: api.configuration().origin,
    visibleVehicles: response.total,
  };
}

async function runFleetSync(api: TollSpotClient) {
  const { data: localVehicles, error: localError } = await adminClient!
    .from("vehicles")
    .select("id,name,brand,model,vehicle_type,plate_number,vin,status,created_at,tollspot_enabled,tollspot_vehicle_type,plate_state,plate_country,plate_assigned_at,model_year")
    .eq("tollspot_enabled", true)
    .neq("id", "00000000-0000-4000-8000-000000000015")
    .order("created_at");
  if (localError) throw localError;

  const remoteVehicles = await api.listVehicles();
  const remotePlates = await api.listLicensePlates();
  const remoteAssignments = await api.listPlateAssignments();
  const results: Record<string, unknown>[] = [];

  for (const local of (localVehicles || []) as LocalVehicle[]) {
    let validated: { vin: string; plate: string };
    try {
      validated = validateLocalVehicle(local);
    } catch (error) {
      results.push({
        vehicleId: local.id,
        vehicleName: local.name,
        status: "error",
        error: error instanceof Error ? error.message : "Vehicle validation failed.",
      });
      continue;
    }

    let remoteVehicle = remoteVehicles.data.find((vehicle) => String(vehicle.local_id || "") === local.id);
    if (!remoteVehicle && validated.vin) {
      const vinPrefix = validated.vin.slice(0, 12);
      const vinMatches = remoteVehicles.data.filter((vehicle) =>
        String(vehicle.vin || "").toUpperCase().startsWith(vinPrefix)
      );
      if (vinMatches.length === 1) remoteVehicle = vinMatches[0];
      if (vinMatches.length > 1) {
        results.push({
          vehicleId: local.id,
          vehicleName: local.name,
          status: "error",
          error: "More than one TollSpot vehicle has the same VIN prefix.",
        });
        continue;
      }
    }
    if (!remoteVehicle) {
      remoteVehicle = await api.addVehicle({
        vin: validated.vin ? validated.vin.slice(0, 12) : null,
        easy_name: cleanText(local.name, 100),
        local_id: local.id,
        year: local.model_year,
        vehicle_make: String(local.brand).trim().slice(0, 50),
        vehicle_model: String(local.model).trim().slice(0, 50),
        vehicle_type: local.tollspot_vehicle_type,
        custom_data1: null,
        custom_data2: null,
        status: providerVehicleStatus(local.status),
      });
      remoteVehicles.data.push(remoteVehicle);
    }

    const state = String(local.plate_state).toUpperCase();
    const country = String(local.plate_country).toUpperCase();
    let remotePlate = remotePlates.data.find((plate) =>
      normalizedPlate(plate.license_plate) === validated.plate &&
      String(plate.state || "").toUpperCase() === state &&
      String(plate.country || "").toUpperCase() === country
    );
    if (!remotePlate) {
      remotePlate = await api.addLicensePlate({
        license_plate: validated.plate,
        state,
        country,
      });
      remotePlates.data.push(remotePlate);
    }

    let assignment = remoteAssignments.data.find((item) =>
      String(item.vehicle_id) === String(remoteVehicle!.id) &&
      String(item.license_plate_id) === String(remotePlate!.id) &&
      !item.removed_at
    );
    if (!assignment) {
      assignment = await api.assignLicensePlate({
        license_plate_id: Number(remotePlate.id),
        vehicle_id: Number(remoteVehicle.id),
        assigned_at: parseTimestamp(local.plate_assigned_at, "plate effective time"),
      });
      remoteAssignments.data.push(assignment);
    }

    const mappingPayload = {
      vehicle_id: local.id,
      tollspot_vehicle_id: String(remoteVehicle.id),
      tollspot_license_plate_id: String(remotePlate.id),
      tollspot_assignment_id: String(assignment.id),
      provider_plate_snapshot: validated.plate,
      provider_plate_state_snapshot: state,
      provider_plate_country_snapshot: country,
      provider_vin_snapshot: validated.vin ? `${validated.vin.slice(0, 8)}••••` : null,
      provider_vehicle_type: local.tollspot_vehicle_type,
      assignment_effective_at: parseTimestamp(local.plate_assigned_at, "plate effective time"),
      desired_provider_status: providerVehicleStatus(local.status),
      sync_status: "synced",
      active: true,
      last_sync_attempt_at: new Date().toISOString(),
      last_synced_at: new Date().toISOString(),
      last_error_code: null,
      last_error_message: null,
      updated_at: new Date().toISOString(),
    };
    const { error: mappingError } = await adminClient!
      .from("tollspot_vehicle_mappings")
      .upsert(mappingPayload, { onConflict: "tollspot_vehicle_id" });
    if (mappingError) throw mappingError;

    const { error: assignmentError } = await adminClient!
      .from("tollspot_plate_assignments")
      .upsert({
        vehicle_id: local.id,
        tollspot_vehicle_id: String(remoteVehicle.id),
        tollspot_license_plate_id: String(remotePlate.id),
        tollspot_assignment_id: String(assignment.id),
        plate_number: validated.plate,
        plate_state: state,
        plate_country: country,
        assigned_at: parseTimestamp(assignment.assigned_at, "assignment time"),
        removed_at: assignment.removed_at
          ? parseTimestamp(assignment.removed_at, "assignment removal time")
          : null,
        raw_assignment: assignment,
        updated_at: new Date().toISOString(),
      }, { onConflict: "tollspot_assignment_id" });
    if (assignmentError) throw assignmentError;

    results.push({
      vehicleId: local.id,
      vehicleName: local.name,
      status: "synced",
      tollspotVehicleId: String(remoteVehicle.id),
    });
  }
  return {
    eligible: localVehicles?.length || 0,
    synced: results.filter((item) => item.status === "synced").length,
    errors: results.filter((item) => item.status === "error").length,
    results,
    pages: remoteVehicles.pages + remotePlates.pages + remoteAssignments.pages,
  };
}

function normalizedCharge(charge: TollSpotCharge) {
  const amount = Number(charge.amount);
  if (!Number.isFinite(amount) || amount < 0) {
    throw new TollSpotApiError("TollSpot returned an invalid charge amount.", 0, "INVALID_PROVIDER_RECORD");
  }
  const rawTransactionType = cleanText(charge.transaction_type, 20)?.toUpperCase() || null;
  const transactionType = rawTransactionType === "TOLL" ? "TOLLS" : rawTransactionType;
  if (transactionType && !["TOLLS", "PARKING", "VIOLATION"].includes(transactionType)) {
    throw new TollSpotApiError(
      "TollSpot returned an unsupported transaction type.",
      0,
      "INVALID_PROVIDER_RECORD",
    );
  }
  const entryLocation = cleanText(charge.entry_location, 500);
  const exitLocation = cleanText(charge.exit_location, 500);
  return {
    tollspot_transaction_id: cleanIdentifier(charge.id),
    tollspot_vehicle_id: charge.vehicle_id === null || charge.vehicle_id === undefined
      ? null
      : String(charge.vehicle_id),
    occurred_at: parseTimestamp(charge.exit_time, "exit time"),
    posted_at: parseTimestamp(charge.posted_time, "posted time"),
    entry_at: parseTimestamp(charge.entry_time, "entry time", true),
    entry_location: entryLocation,
    exit_location: exitLocation,
    agency: cleanText(charge.agency, 500),
    road_or_plaza: [entryLocation, exitLocation].filter(Boolean).join(" → ").slice(0, 500) || null,
    transaction_type: transactionType,
    license_plate: cleanText(charge.license_plate, 20),
    license_plate_state: cleanText(charge.license_plate_state, 3)?.toUpperCase() || null,
    license_plate_country: cleanText(charge.license_plate_country, 3)?.toUpperCase() || null,
    transponder_number: cleanText(charge.transponder_number, 200),
    transponder_or_plate: cleanText(charge.transponder_number || charge.license_plate, 200),
    host_id: cleanText(charge.host_id, 200),
    partner_vehicle_id: cleanText(charge.partner_vehicle_id, 200),
    vin_snapshot: cleanText(charge.vin, 17),
    toll_amount: Math.round(amount * 100) / 100,
    admin_fee: 0,
    currency: "usd",
    raw_transaction: charge,
  };
}

const stableTollFields = [
  "tollspot_vehicle_id",
  "occurred_at",
  "posted_at",
  "entry_at",
  "entry_location",
  "exit_location",
  "agency",
  "road_or_plaza",
  "transaction_type",
  "license_plate",
  "license_plate_state",
  "license_plate_country",
  "transponder_number",
  "transponder_or_plate",
  "host_id",
  "partner_vehicle_id",
  "vin_snapshot",
  "toll_amount",
  "admin_fee",
  "currency",
] as const;

function sameStableTollRecord(
  next: ReturnType<typeof normalizedCharge>,
  existing: Record<string, unknown>,
) {
  return stableTollFields.every((field) => {
    const nextValue = next[field];
    const existingValue = existing[field];
    if (nextValue === null || nextValue === undefined) {
      return existingValue === null || existingValue === undefined || existingValue === "";
    }
    if (typeof nextValue === "number") return Number(existingValue) === nextValue;
    if (["occurred_at", "posted_at", "entry_at"].includes(field)) {
      const nextTime = new Date(String(nextValue)).getTime();
      const existingTime = new Date(String(existingValue)).getTime();
      return !Number.isNaN(nextTime) && nextTime === existingTime;
    }
    return String(existingValue) === String(nextValue);
  });
}

function shouldRetryUnchangedMatch(existing: Record<string, unknown>, now: Date) {
  const status = String(existing.status || "received").toLowerCase();
  if (status === "received") return true;
  if (status !== "needs_review") return false;
  const lastAttempt = new Date(String(existing.updated_at || ""));
  return Number.isNaN(lastAttempt.getTime()) || now.getTime() - lastAttempt.getTime() >= 86_400_000;
}

async function runTollSync(api: TollSpotClient, fromDate: Date, toDate: Date) {
  const response = await api.listTollCharges({
    from_date: formatApiDate(fromDate),
    to_date: formatApiDate(toDate),
  });
  const normalized = response.data.map(normalizedCharge);
  const ids = normalized.map((charge) => charge.tollspot_transaction_id);
  const { data: existing, error: existingError } = ids.length
    ? await adminClient!
      .from("tollspot_transactions")
      .select(`
        id,tollspot_transaction_id,status,updated_at,
        tollspot_vehicle_id,occurred_at,posted_at,entry_at,entry_location,exit_location,
        agency,road_or_plaza,transaction_type,license_plate,license_plate_state,
        license_plate_country,transponder_number,transponder_or_plate,host_id,
        partner_vehicle_id,vin_snapshot,toll_amount,admin_fee,currency
      `)
      .in("tollspot_transaction_id", ids)
    : { data: [], error: null };
  if (existingError) throw existingError;
  const existingByProviderId = new Map(
    (existing || []).map((item) => [String(item.tollspot_transaction_id), item as Record<string, unknown>]),
  );
  const created = normalized.filter((charge) => !existingByProviderId.has(charge.tollspot_transaction_id));
  const changed = normalized.filter((charge) => {
    const prior = existingByProviderId.get(charge.tollspot_transaction_id);
    return Boolean(prior) && !sameStableTollRecord(charge, prior!);
  });
  const unchanged = normalized.filter((charge) => {
    const prior = existingByProviderId.get(charge.tollspot_transaction_id);
    return Boolean(prior) && sameStableTollRecord(charge, prior!);
  });
  const now = new Date();
  const rowsToWrite = [...created, ...changed].map((charge) => ({
    ...charge,
    provider_updated_at: now.toISOString(),
    updated_at: now.toISOString(),
  }));

  let writtenRows: Array<Record<string, unknown>> = [];
  if (rowsToWrite.length) {
    const { data: upserted, error: upsertError } = await adminClient!
      .from("tollspot_transactions")
      .upsert(rowsToWrite, { onConflict: "tollspot_transaction_id" })
      .select("id,tollspot_transaction_id,status,updated_at");
    if (upsertError) throw upsertError;
    writtenRows = (upserted || []) as Array<Record<string, unknown>>;
  }

  const writtenIds = new Set(writtenRows.map((row) => String(row.tollspot_transaction_id)));
  const rowsToMatch = [
    ...writtenRows,
    ...unchanged
      .map((charge) => existingByProviderId.get(charge.tollspot_transaction_id))
      .filter((row): row is Record<string, unknown> => Boolean(row))
      .filter((row) => !writtenIds.has(String(row.tollspot_transaction_id)))
      .filter((row) => shouldRetryUnchangedMatch(row, now)),
  ];

  if (rowsToMatch.length) {
    const { error: transponderError } = await adminClient!.rpc(
      "service_apply_tollspot_transponder_mappings",
      { p_transaction_ids: rowsToMatch.map((row) => row.id) },
    );
    if (transponderError && !/service_apply_tollspot_transponder_mappings|schema cache|does not exist/i.test(transponderError.message || "")) {
      throw transponderError;
    }
  }

  let matched = 0;
  let chargesCreated = 0;
  let needsReview = 0;
  if (rowsToMatch.length) {
    const { data, error } = await adminClient!.rpc("service_match_tollspot_transactions", {
      p_transaction_ids: rowsToMatch.map((row) => row.id),
    });
    if (error) throw error;
    for (const result of data || []) {
      if (result.status === "matched") matched += 1;
      if (result.status === "charge_created") {
        matched += 1;
        chargesCreated += 1;
      }
      if (result.status === "needs_review") needsReview += 1;
    }
  }
  return {
    total: response.total,
    received: normalized.length,
    created: created.length,
    updated: changed.length,
    unchanged: unchanged.length,
    matchAttempts: rowsToMatch.length,
    matched,
    chargesCreated,
    needsReview,
    pages: response.pages,
  };
}

async function assignTransponder(body: Record<string, unknown>, userId: string | null) {
  if (!userId) throw new Error("An authenticated administrator is required to assign a transponder.");
  const transponderNumber = normalizedTransponder(body.transponderNumber);
  const vehicleId = String(body.vehicleId || "").trim();
  if (!transponderNumber) throw new Error("A transponder number is required.");
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(vehicleId)) {
    throw new Error("Choose a valid Rent Me CT fleet vehicle.");
  }

  const [{ data: vehicleMapping, error: vehicleError }, { data: existingMapping }] = await Promise.all([
    adminClient!.from("tollspot_vehicle_mappings").select("vehicle_id,tollspot_vehicle_id").eq("vehicle_id", vehicleId).eq("active", true).maybeSingle(),
    adminClient!.from("tollspot_transponder_mappings").select("vehicle_id").eq("transponder_number", transponderNumber).maybeSingle(),
  ]);
  if (vehicleError || !vehicleMapping?.tollspot_vehicle_id) {
    throw new Error("Sync this fleet vehicle with TollSpot before assigning its transponder.");
  }
  if (existingMapping?.vehicle_id && existingMapping.vehicle_id !== vehicleId) {
    throw new Error("This transponder is already verified to a different vehicle. Review its physical assignment before changing history.");
  }

  const { data: firstSeen } = await adminClient!
    .from("tollspot_transactions")
    .select("occurred_at")
    .eq("transponder_number", transponderNumber)
    .order("occurred_at", { ascending: true })
    .limit(1)
    .maybeSingle();
  const { error: mappingError } = await adminClient!.from("tollspot_transponder_mappings").upsert({
    transponder_number: transponderNumber,
    vehicle_id: vehicleId,
    tollspot_vehicle_id: String(vehicleMapping.tollspot_vehicle_id),
    first_seen_at: firstSeen?.occurred_at || new Date().toISOString(),
    verified_by: userId,
    verified_at: new Date().toISOString(),
    active: true,
    updated_at: new Date().toISOString(),
  }, { onConflict: "transponder_number" });
  if (mappingError) throw mappingError;

  const { data: candidates, error: candidateError } = await adminClient!
    .from("tollspot_transactions")
    .select("id")
    .eq("transponder_number", transponderNumber)
    .in("status", ["received", "needs_review", "matched"])
    .limit(1000);
  if (candidateError) throw candidateError;
  const ids = (candidates || []).map((row) => row.id);
  if (ids.length) {
    const { error: applyError } = await adminClient!.rpc("service_apply_tollspot_transponder_mappings", { p_transaction_ids: ids });
    if (applyError) throw applyError;
    const { error: matchError } = await adminClient!.rpc("service_match_tollspot_transactions", { p_transaction_ids: ids });
    if (matchError) throw matchError;
  }

  await adminClient!.from("admin_audit_logs").insert({
    actor_user_id: userId,
    actor_role: "admin",
    action: "tollspot.transponder_assigned",
    entity_type: "vehicle",
    entity_id: vehicleId,
    metadata: { transponder_last_four: transponderNumber.slice(-4), reprocessed_transactions: ids.length },
  });
  return { ok: true, assigned: true, reprocessed: ids.length, transponderLastFour: transponderNumber.slice(-4) };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);
  if (!adminClient) return json({ error: "Server configuration is incomplete." }, 503);

  const authorization = await authorize(req);
  if (!authorization.authorized) return json({ error: "Admin or scheduler authorization is required." }, 401);

  let body: Record<string, unknown>;
  try {
    const raw = await req.text();
    if (raw.length > 16_384) return json({ error: "Request is too large." }, 413);
    body = raw ? JSON.parse(raw) : {};
  } catch {
    return json({ error: "A valid JSON request is required." }, 400);
  }
  const action = String(body.action || "health") as Action;
  if (!["health", "sync_fleet", "sync_tolls", "backfill_tolls", "run_all", "assign_transponder"].includes(action)) {
    return json({ error: "Unsupported TollSpot action." }, 400);
  }
  if (authorization.source === "schedule" && action !== "health") {
    const { data: settings, error: settingsError } = await adminClient
      .from("billing_automation_settings")
      .select("tollspot_automatic_sync_enabled")
      .eq("id", true)
      .maybeSingle();
    if (settingsError || settings?.tollspot_automatic_sync_enabled !== true) {
      return json({ error: "Scheduled TollSpot sync is disabled in Billing Automation settings." }, 503);
    }
  }
  if (action === "assign_transponder") {
    if (authorization.source !== "admin") return json({ error: "Administrator access is required." }, 403);
    try {
      return json(await assignTransponder(body, authorization.userId));
    } catch (error) {
      return json({ error: error instanceof Error ? error.message : "The transponder could not be assigned." }, 409);
    }
  }
  if (!tollspotBaseUrl) {
    return json({
      error: "TollSpot API base URL is not configured.",
      code: "MISSING_BASE_URL",
      configured: { apiKey: Boolean(tollspotApiKey), apiVersion: tollspotApiVersion },
    }, 503);
  }

  let runId: string | null = null;
  try {
    const api = client();
    const now = new Date();
    const defaultFrom = body.fromDate
      ? new Date(now)
      : await defaultTollStartDate(action, now);
    const fromDate = parseRequestedDate(body.fromDate, defaultFrom);
    const toDate = parseRequestedDate(body.toDate, now);
    if (toDate < fromDate) return json({ error: "toDate must be on or after fromDate." }, 400);
    const rangeDays = Math.ceil((toDate.getTime() - fromDate.getTime()) / 86_400_000);
    if (rangeDays > 366) return json({ error: "TollSpot date range cannot exceed 366 days." }, 400);

    runId = await createRun(action, authorization.source, authorization.userId, fromDate, toDate);
    if (action === "health") {
      const health = await runHealth(api);
      await finishRun(runId, { status: "succeeded", metadata: health });
      return json({ ok: true, ...health });
    }
    if (action === "sync_fleet") {
      const fleet = await runFleetSync(api);
      await finishRun(runId, {
        status: fleet.errors ? "partial" : "succeeded",
        pages_processed: fleet.pages,
        records_received: fleet.eligible,
        records_updated: fleet.synced,
        records_needing_review: fleet.errors,
        metadata: { results: fleet.results },
      });
      return json({ ok: !fleet.errors, ...fleet }, fleet.errors ? 207 : 200);
    }
    if (action === "sync_tolls" || action === "backfill_tolls") {
      const tolls = await runTollSync(api, fromDate, toDate);
      await finishRun(runId, {
        status: "succeeded",
        pages_processed: tolls.pages,
        records_received: tolls.received,
        records_created: tolls.created,
        records_updated: tolls.updated,
        records_matched: tolls.matched,
        records_needing_review: tolls.needsReview,
      });
      return json({ ok: true, ...tolls });
    }

    const fleet = await runFleetSync(api);
    const tolls = await runTollSync(api, fromDate, toDate);
    await finishRun(runId, {
      status: fleet.errors ? "partial" : "succeeded",
      pages_processed: fleet.pages + tolls.pages,
      records_received: fleet.eligible + tolls.received,
      records_created: tolls.created,
      records_updated: fleet.synced + tolls.updated,
      records_matched: tolls.matched,
      records_needing_review: fleet.errors + tolls.needsReview,
      metadata: { fleetResults: fleet.results },
    });
    return json({ ok: !fleet.errors, fleet, tolls }, fleet.errors ? 207 : 200);
  } catch (error) {
    console.error("TollSpot sync failed", {
      code: error instanceof TollSpotApiError ? error.code : "SYNC_FAILED",
      status: error instanceof TollSpotApiError ? error.status : 0,
      message: error instanceof Error ? error.message : "Unknown error",
    });
    await failRun(runId, error);
    const apiError = error instanceof TollSpotApiError ? error : null;
    return json({
      error: error instanceof Error ? error.message : "TollSpot sync failed.",
      code: apiError?.code || "SYNC_FAILED",
    }, apiError?.status && apiError.status >= 400 ? apiError.status : 502);
  }
});
