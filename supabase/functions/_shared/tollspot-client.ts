export type TollSpotVehicle = {
  id: number | string;
  vin?: string | null;
  easy_name?: string | null;
  local_id?: string | null;
  year?: number | null;
  vehicle_make: string;
  vehicle_model: string;
  vehicle_type: string;
  status?: string | null;
  created_at?: string;
  updated_at?: string;
};

export type TollSpotLicensePlate = {
  id: number | string;
  license_plate: string;
  country: string;
  state: string;
  created_at?: string;
  updated_at?: string;
};

export type TollSpotPlateAssignment = {
  id: number | string;
  license_plate_id: number | string;
  vehicle_id: number | string;
  assigned_at: string;
  removed_at?: string | null;
  created_at?: string;
  updated_at?: string;
};

export type TollSpotCharge = {
  id: number | string;
  posted_time: string;
  entry_time?: string | null;
  entry_location?: string | null;
  exit_time: string;
  exit_location: string;
  amount: number;
  transaction_type?: "PARKING" | "TOLL" | "TOLLS" | "VIOLATION" | null;
  license_plate?: string | null;
  license_plate_state?: string | null;
  license_plate_country?: string | null;
  transponder_number?: string | null;
  agency: string;
  host_id?: string | null;
  partner_vehicle_id?: string | null;
  vehicle_id?: number | string | null;
  vin?: string | null;
};

type PaginatedResponse<T> = {
  total: number;
  data: T[];
};

type RequestOptions = {
  method?: "GET" | "POST" | "PATCH";
  query?: Record<string, string | number | undefined | null>;
  body?: Record<string, unknown>;
};

export class TollSpotApiError extends Error {
  status: number;
  code: string;
  retryAfterSeconds: number | null;

  constructor(message: string, status = 0, code = "TOLLSPOT_REQUEST_FAILED", retryAfterSeconds: number | null = null) {
    super(message);
    this.name = "TollSpotApiError";
    this.status = status;
    this.code = code;
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

function sleep(milliseconds: number) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function safeMessage(payload: unknown, fallback: string) {
  if (!payload || typeof payload !== "object") return fallback;
  const record = payload as Record<string, unknown>;
  const message = String(record.message || record.error || fallback).trim();
  return message.slice(0, 500);
}

function safeCode(payload: unknown, fallback: string) {
  if (!payload || typeof payload !== "object") return fallback;
  const record = payload as Record<string, unknown>;
  return String(record.error || record.code || fallback).trim().slice(0, 100);
}

export class TollSpotClient {
  private readonly origin: string;
  private readonly baseUrl: string;
  private readonly apiKey: string;
  private readonly apiVersion: string;
  private readonly timeoutMilliseconds: number;

  constructor(options: {
    baseUrl: string;
    apiKey: string;
    apiVersion?: string;
    timeoutMilliseconds?: number;
  }) {
    if (!options.apiKey) throw new TollSpotApiError("TollSpot API key is not configured.", 0, "MISSING_API_KEY");
    let parsed: URL;
    try {
      parsed = new URL(options.baseUrl);
    } catch {
      throw new TollSpotApiError("TollSpot API base URL is invalid.", 0, "INVALID_BASE_URL");
    }
    if (parsed.protocol !== "https:") {
      throw new TollSpotApiError("TollSpot API base URL must use HTTPS.", 0, "INSECURE_BASE_URL");
    }
    const hostname = parsed.hostname.toLowerCase();
    const isTrustedTollSpotHost = hostname === "selfserve.tollspot.app" ||
      /(^|\.)tollspot\.com$/i.test(hostname);
    if (!isTrustedTollSpotHost) {
      throw new TollSpotApiError("TollSpot API base URL must use an approved TollSpot host.", 0, "UNTRUSTED_BASE_URL");
    }
    parsed.search = "";
    parsed.hash = "";
    this.origin = parsed.origin;
    this.baseUrl = parsed.toString().replace(/\/$/, "");
    this.apiKey = options.apiKey;
    this.apiVersion = options.apiVersion || "1.0.0";
    this.timeoutMilliseconds = options.timeoutMilliseconds || 15_000;
  }

  configuration() {
    return { origin: this.origin, apiVersion: this.apiVersion };
  }

  async request<T>(path: string, options: RequestOptions = {}): Promise<T> {
    const normalizedPath = `/${String(path || "").replace(/^\/+/, "")}`;
    const url = new URL(`${this.baseUrl}${normalizedPath}`);
    if (url.origin !== this.origin) {
      throw new TollSpotApiError("TollSpot request escaped the configured origin.", 0, "UNTRUSTED_REQUEST_URL");
    }
    for (const [key, value] of Object.entries(options.query || {})) {
      if (value !== undefined && value !== null && value !== "") {
        url.searchParams.set(key, String(value));
      }
    }

    let lastError: unknown;
    for (let attempt = 0; attempt < 4; attempt += 1) {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), this.timeoutMilliseconds);
      try {
        const response = await fetch(url, {
          method: options.method || "GET",
          headers: {
            "Accept": "application/json",
            "Content-Type": "application/json",
            "X-API-KEY": this.apiKey,
            "X-API-VERSION": this.apiVersion,
          },
          body: options.body ? JSON.stringify(options.body) : undefined,
          signal: controller.signal,
        });
        clearTimeout(timeout);

        const responseText = await response.text();
        let payload: unknown = null;
        if (responseText) {
          try {
            payload = JSON.parse(responseText);
          } catch {
            throw new TollSpotApiError(
              "TollSpot returned a non-JSON response.",
              response.status,
              "INVALID_PROVIDER_RESPONSE",
            );
          }
        }
        if (response.ok) return payload as T;

        const retryAfterHeader = response.headers.get("retry-after");
        const retryAfterSeconds = retryAfterHeader && /^\d+$/.test(retryAfterHeader)
          ? Number(retryAfterHeader)
          : null;
        const apiError = new TollSpotApiError(
          safeMessage(payload, `TollSpot request failed with HTTP ${response.status}.`),
          response.status,
          safeCode(payload, `HTTP_${response.status}`),
          retryAfterSeconds,
        );
        if (![429, 500, 502, 503, 504].includes(response.status) || attempt === 3) throw apiError;
        lastError = apiError;
        const retryDelay = retryAfterSeconds !== null
          ? Math.min(retryAfterSeconds * 1000, 30_000)
          : Math.min(500 * (2 ** attempt) + Math.floor(Math.random() * 250), 5_000);
        await sleep(retryDelay);
      } catch (error) {
        clearTimeout(timeout);
        if (error instanceof TollSpotApiError) throw error;
        lastError = error;
        if (attempt === 3) {
          const timedOut = error instanceof DOMException && error.name === "AbortError";
          throw new TollSpotApiError(
            timedOut ? "TollSpot request timed out." : "TollSpot could not be reached.",
            0,
            timedOut ? "PROVIDER_TIMEOUT" : "PROVIDER_UNREACHABLE",
          );
        }
        await sleep(Math.min(500 * (2 ** attempt) + Math.floor(Math.random() * 250), 5_000));
      }
    }
    throw lastError instanceof Error
      ? lastError
      : new TollSpotApiError("TollSpot request failed.");
  }

  async listAll<T>(
    path: string,
    query: Record<string, string | number | undefined | null> = {},
  ): Promise<{ total: number; data: T[]; pages: number }> {
    const results: T[] = [];
    const limit = 100;
    let page = 0;
    let expectedTotal = Number.POSITIVE_INFINITY;
    while (results.length < expectedTotal) {
      if (page >= 1_000) {
        throw new TollSpotApiError("TollSpot pagination exceeded the safety limit.", 0, "PAGINATION_LIMIT");
      }
      const response = await this.request<PaginatedResponse<T>>(path, {
        query: { ...query, page, limit },
      });
      if (!response || !Array.isArray(response.data) || !Number.isFinite(Number(response.total))) {
        throw new TollSpotApiError("TollSpot returned an invalid paginated response.", 0, "INVALID_PROVIDER_RESPONSE");
      }
      expectedTotal = Math.max(0, Number(response.total));
      results.push(...response.data);
      page += 1;
      if (response.data.length === 0 || response.data.length < limit) break;
    }
    return { total: expectedTotal, data: results, pages: page };
  }

  listVehicles() {
    return this.listAll<TollSpotVehicle>("/vehicle");
  }

  addVehicle(body: Record<string, unknown>) {
    return this.request<TollSpotVehicle>("/vehicle", { method: "POST", body });
  }

  listLicensePlates() {
    return this.listAll<TollSpotLicensePlate>("/license-plate");
  }

  addLicensePlate(body: Record<string, unknown>) {
    return this.request<TollSpotLicensePlate>("/license-plate", { method: "POST", body });
  }

  listPlateAssignments() {
    return this.listAll<TollSpotPlateAssignment>("/plate-assignments");
  }

  assignLicensePlate(body: Record<string, unknown>) {
    return this.request<TollSpotPlateAssignment>("/plate-assignments", { method: "POST", body });
  }

  unassignLicensePlate(id: string, removedAt: string) {
    return this.request<TollSpotPlateAssignment>(`/plate-assignments/${encodeURIComponent(id)}`, {
      method: "PATCH",
      body: { id: Number(id), removed_at: removedAt },
    });
  }

  listTollCharges(query: Record<string, string | number | undefined | null>) {
    return this.listAll<TollSpotCharge>("/toll-charge", query);
  }
}
