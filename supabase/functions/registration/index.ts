const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};

export const alphabet = "abcdefghjkmnpqrstuvwxyz23456789";

const encoder = new TextEncoder();
let createClient;

export function normalizeCode(value) {
  return typeof value === "string" ? value.toLowerCase().replaceAll(/\s/g, "") : "";
}

export function isValidCode(code) {
  return new RegExp(`^[${alphabet}]{8}$`).test(code);
}

export function randomCode() {
  const result = [];
  const limit = Math.floor(256 / alphabet.length) * alphabet.length;
  while (result.length < 8) {
    const [byte] = crypto.getRandomValues(new Uint8Array(1));
    if (byte < limit) result.push(alphabet[byte % alphabet.length]);
  }
  return result.join("");
}

export async function hashCode(code, pepper) {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(pepper),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(code));
  return Array.from(new Uint8Array(signature), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function isUuid(value) {
  return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function projectSecret() {
  try {
    return JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}").default
      ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  } catch {
    return null;
  }
}

function response(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

async function recordQueryResult(database, success) {
  const { error } = await database.rpc("record_query_result", { p_success: success });
  if (!error) return true;
  console.error("Failed to record query result", error);
  return false;
}

export async function handler(request) {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (!['GET', 'POST'].includes(request.method)) return response({ error: "METHOD_NOT_ALLOWED" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const secretKey = projectSecret();
  const pepper = Deno.env.get("QUERY_CODE_PEPPER");
  if (!url || !secretKey || !pepper || pepper.length < 32) {
    console.error("Missing required Edge Function secrets");
    return response({ error: "服務暫時無法使用" }, 503);
  }

  const database = createClient(url, secretKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  if (request.method === "GET") {
    const [settings, districts, activities, program] = await Promise.all([
      database.from("site_settings").select("event_name,venue,address,registration_deadline_at,is_registration_open").single(),
      database.from("districts").select("id,name").eq("is_active", true).order("sort_order"),
      database.from("activities").select("id,category,title,starts_at,ends_at,venue,address,map_url,description,fee_amount").eq("is_published", true).order("sort_order"),
      database.from("program_items").select("event_date,start_time,end_time,title,note").eq("is_visible", true).order("sort_order"),
    ]);
    const failed = [settings, districts, activities, program].find((result) => result.error);
    if (failed?.error) {
      console.error(failed.error.message);
      return response({ error: "無法載入登記資料" }, 503);
    }
    return response({ settings: settings.data, districts: districts.data, activities: activities.data, program: program.data });
  }

  let body;
  try {
    const rawBody = await request.text();
    if (new TextEncoder().encode(rawBody).byteLength > 64_000) {
      return response({ error: "REQUEST_TOO_LARGE" }, 413);
    }
    body = JSON.parse(rawBody);
  } catch {
    return response({ error: "INVALID_REQUEST" }, 400);
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return response({ error: "INVALID_REQUEST" }, 400);
  }

  // shortcut: Turnstile stays disabled for launch; verify body.turnstile_token here when enabled.
  const action = body.action;

  if (action === "create") {
    const startedAt = Number(body.started_at);
    if (body.website || !Number.isFinite(startedAt) || Date.now() - startedAt < 3_000 || Date.now() - startedAt > 86_400_000) {
      return response({ error: "INVALID_REQUEST" }, 400);
    }
    if (!isUuid(body.create_request_id)) return response({ error: "INVALID_REQUEST" }, 400);

    for (let attempt = 0; attempt < 5; attempt += 1) {
      const code = randomCode();
      const codeHash = await hashCode(code, pepper);
      const { error } = await database.rpc("create_registration", {
        p_request_id: body.create_request_id,
        p_full_name: body.full_name,
        p_district_id: body.district_id,
        p_query_code_hash: codeHash,
        p_choices: body.choices,
      });
      if (!error) {
        return response({ query_code: code }, 201);
      }
      if (error.message.includes("DUPLICATE_REQUEST")) return response({ error: "DUPLICATE_REQUEST" }, 409);
      if (error.code !== "23505") {
        if (error.message.includes("CREATE_RATE_LIMITED")) return response({ error: "登記暫時忙碌，請稍後再試" }, 429);
        if (error.message.includes("REGISTRATION_CLOSED")) return response({ error: "登記目前未開放" }, 409);
        if (error.code === "22023") return response({ error: "請檢查登記資料" }, 400);
        console.error(error.message);
        return response({ error: "登記失敗，請稍後再試" }, 500);
      }
    }
    return response({ error: "登記失敗，請稍後再試" }, 500);
  }

  if (!["query", "update"].includes(String(action))) {
    return response({ error: "INVALID_ACTION" }, 400);
  }

  const { data: available, error: availabilityError } = await database.rpc("check_query_availability");
  if (availabilityError || !available) {
    if (availabilityError) console.error("Failed to check query availability", availabilityError);
    return response({ error: "查詢功能暫時停止，請稍後再試" }, 503);
  }

  const code = normalizeCode(body.query_code);
  if (!isValidCode(code)) {
    if (!await recordQueryResult(database, false)) {
      return response({ error: "服務暫時無法使用" }, 503);
    }
    return response({ error: "無法查詢登記資料，請確認查詢碼後再試一次" }, 404);
  }
  const codeHash = await hashCode(code, pepper);

  if (action === "query") {
    const { data, error } = await database.rpc("get_registration", { p_query_code_hash: codeHash });
    const found = !error && data?.length === 1;
    if (!await recordQueryResult(database, found)) {
      return response({ error: "服務暫時無法使用" }, 503);
    }
    if (!found) return response({ error: "無法查詢登記資料，請確認查詢碼後再試一次" }, 404);
    const registration = data[0];
    const { serial_no: _serialNo, ...publicRegistration } = registration;
    return response(publicRegistration);
  }

  const { data, error } = await database.rpc("update_registration", {
    p_query_code_hash: codeHash,
    p_full_name: body.full_name,
    p_district_id: body.district_id,
    p_choices: body.choices,
  });
  const found = !error && data === true;
  if (!error || !error.message.includes("REGISTRATION_CLOSED")) {
    if (!await recordQueryResult(database, found)) {
      return response({ error: "服務暫時無法使用" }, 503);
    }
  }
  if (error?.message.includes("REGISTRATION_CLOSED")) return response({ error: "登記已截止，資料只能查看" }, 409);
  if (error?.code === "22023") return response({ error: "請檢查登記資料" }, 400);
  if (!found) return response({ error: "無法查詢登記資料，請確認查詢碼後再試一次" }, 404);
  return response({ success: true });
}

if (typeof Deno !== "undefined") {
  ({ createClient } = await import("npm:@supabase/supabase-js@2.118.0"));
  Deno.serve(handler);
}
