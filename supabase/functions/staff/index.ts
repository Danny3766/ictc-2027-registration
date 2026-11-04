const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "apikey, authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};

let createClient;

function response(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers });
}

// staff_assert_actor raises 42501 when the caller lost access mid-session
// (deactivated, demoted, or a password reset now requires a change).
function lostAccess(error) {
  return error?.code === "42501";
}
const lostAccessResponse = () => response({ error: "帳號權限已變更，請重新登入" }, 403);

function projectKey(name, fallback) {
  try {
    return JSON.parse(Deno.env.get(name) ?? "{}").default ?? Deno.env.get(fallback);
  } catch {
    return null;
  }
}

// Auth hashes with bcrypt, which accepts at most 72 bytes; a Chinese character takes 3.
export function validPassword(value) {
  return typeof value === "string" && value.length >= 12 && new TextEncoder().encode(value).length <= 72;
}

export function validUsername(value) {
  return typeof value === "string" && /^[a-z][a-z0-9_-]{2,30}$/.test(value);
}

function isUuid(value) {
  return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

export const queryAlphabet = "abcdefghjkmnpqrstuvwxyz23456789";
export function randomQueryCode() {
  const result = [];
  const limit = Math.floor(256 / queryAlphabet.length) * queryAlphabet.length;
  while (result.length < 8) {
    const [byte] = crypto.getRandomValues(new Uint8Array(1));
    if (byte < limit) result.push(queryAlphabet[byte % queryAlphabet.length]);
  }
  return result.join("");
}

export async function hashQueryCode(code, pepper) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(pepper),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(code));
  return Array.from(new Uint8Array(signature), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function queryPepper() {
  const pepper = Deno.env.get("QUERY_CODE_PEPPER");
  if (pepper && pepper.length >= 32) return pepper;
  console.error("Missing query code pepper");
  return null;
}

// Retries only a query-code hash collision; every other result goes back to the caller with its code.
export async function withNewQueryCode(pepper, call) {
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const code = randomQueryCode();
    const result = await call(await hashQueryCode(code, pepper));
    const collision = result.error?.code === "23505" && !result.error.message?.includes("DUPLICATE_REQUEST");
    if (!collision) return { code, ...result };
  }
  return { error: { code: "23505", message: "QUERY_CODE_COLLISION" } };
}

export async function handler(request) {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (request.method !== "POST") return response({ error: "METHOD_NOT_ALLOWED" }, 405);

  const token = request.headers.get("Authorization")?.match(/^Bearer (\S+)$/)?.[1];
  if (!token) return response({ error: "請先登入" }, 401);

  const url = Deno.env.get("SUPABASE_URL");
  const publishableKey = projectKey("SUPABASE_PUBLISHABLE_KEYS", "SUPABASE_ANON_KEY");
  const secretKey = projectKey("SUPABASE_SECRET_KEYS", "SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !publishableKey || !secretKey) {
    console.error("Missing staff function configuration");
    return response({ error: "服務暫時無法使用" }, 503);
  }

  const auth = createClient(url, publishableKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const database = createClient(url, secretKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: userData, error: userError } = await auth.auth.getUser(token);
  if (userError || !userData.user) return response({ error: "請重新登入" }, 401);

  const { data: profile, error: profileError } = await database.from("staff_profiles")
    .select("auth_user_id,username,display_name,role,is_active,must_change_password")
    .eq("auth_user_id", userData.user.id).single();
  if (profileError || !profile?.is_active) return response({ error: "沒有操作權限" }, 403);

  let body;
  try {
    const raw = await request.text();
    if (new TextEncoder().encode(raw).byteLength > 64_000) return response({ error: "REQUEST_TOO_LARGE" }, 413);
    body = JSON.parse(raw);
  } catch {
    return response({ error: "INVALID_REQUEST" }, 400);
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) return response({ error: "INVALID_REQUEST" }, 400);

  if (body.action === "me") return response({ profile });
  if (body.action === "change_password") {
    if (typeof body.current_password !== "string" || !body.current_password) return response({ error: "請輸入目前密碼" }, 400);
    if (!validPassword(body.password)) return response({ error: "密碼須至少 12 字元，且不超過 72 bytes（一個中文字約佔 3 bytes）" }, 400);
    if (body.password === body.current_password) return response({ error: "新密碼不可與目前密碼相同" }, 400);
    // Per-user limit: Auth's own sign-in limit counts the shared Edge Function IP, not this caller.
    // The slot is reserved atomically before checking, so parallel guesses cannot exceed it.
    const { data: allowed, error: attemptError } = await database.rpc("staff_reserve_password_attempt", {
      p_actor: profile.auth_user_id,
    });
    if (attemptError) {
      if (lostAccess(attemptError)) return lostAccessResponse();
      console.error("Failed to reserve password verification attempt", attemptError);
      return response({ error: "密碼更新失敗" }, 503);
    }
    if (allowed !== true) return response({ error: "嘗試次數過多，請 15 分鐘後再試" }, 429);
    // A stolen session alone must not be enough to take over the account.
    const { error: verifyError } = await auth.auth.signInWithPassword({
      email: `${profile.username}@accounts.invalid`, password: body.current_password,
    });
    if (verifyError) {
      if (verifyError.code === "invalid_credentials") return response({ error: "目前密碼不正確" }, 403);
      console.error("Failed to verify current staff password", verifyError);
      return response({ error: "密碼更新失敗" }, 503);
    }
    const { error: passwordError } = await database.auth.admin.updateUserById(profile.auth_user_id, { password: body.password });
    if (passwordError) {
      console.error("Failed to change staff password", passwordError);
      return response({ error: "密碼更新失敗" }, 503);
    }
    const { error: finishError } = await database.rpc("staff_finish_password_change", { p_actor: profile.auth_user_id });
    if (finishError) {
      console.error("Failed to finish staff password change", finishError);
      return response({ error: "密碼已變更，請重新登入並完成驗證" }, 503);
    }
    return response({ success: true });
  }

  if (profile.must_change_password) return response({ error: "請先更改初始密碼" }, 403);

  if (body.action === "list_registrations") {
    const page = Number(body.page);
    if (!Number.isInteger(page) || page < 0 || page > 10000) return response({ error: "INVALID_REQUEST" }, 400);
    // before_serial pages by key, so rows inserted during a full export cannot shift or duplicate pages.
    const beforeSerial = body.before_serial === undefined ? null : Number(body.before_serial);
    if (beforeSerial !== null && (!Number.isSafeInteger(beforeSerial) || beforeSerial < 1)) {
      return response({ error: "INVALID_REQUEST" }, 400);
    }
    let query = database.from("registrations")
      .select("id,serial_no,full_name,district_id,record_status,import_status,duplicate_review_status,created_at,updated_at,registration_choices(activity_id,attending)",
        beforeSerial === null ? { count: "exact" } : undefined)
      .order("serial_no", { ascending: false });
    query = beforeSerial === null ? query.range(page * 100, page * 100 + 99)
      : query.lt("serial_no", beforeSerial).limit(500);
    if (body.search) {
      if (typeof body.search !== "string" || body.search.length > 100) return response({ error: "INVALID_REQUEST" }, 400);
      // More than 15 digits loses precision in Number, so treat it as a name search instead.
      query = /^\d{1,15}$/.test(body.search) ? query.eq("serial_no", Number(body.search))
        : query.ilike("full_name", `%${body.search.replaceAll(/[%*,()]/g, "").replaceAll(/[\\_]/g, "\\$&")}%`);
    }
    const { data, count, error } = await query;
    if (error) {
      console.error("Failed to list registrations", error);
      return response({ error: "名單載入失敗" }, 503);
    }
    return response({ registrations: data, count });
  }

  if (body.action === "list_reference") {
    const [settings, districts, activities, program] = await Promise.all([
      database.from("site_settings").select("event_name,venue,address,registration_deadline_at,is_registration_open").single(),
      database.from("districts").select("id,name,is_active,sort_order").order("sort_order"),
      database.from("activities").select("id,category,title,starts_at,ends_at,venue,address,map_url,description,fee_amount,is_published,sort_order").order("sort_order"),
      database.from("program_items").select("id,event_date,start_time,end_time,title,note,sort_order,is_visible").order("sort_order"),
    ]);
    if ([settings, districts, activities, program].some((item) => item.error)) {
      console.error("Failed to load staff reference data", [settings, districts, activities, program].map((item) => item.error));
      return response({ error: "後台資料載入失敗" }, 503);
    }
    return response({ settings: settings.data, districts: districts.data, activities: activities.data, program: program.data });
  }

  if (["save_registration", "set_import_status", "mark_duplicate"].includes(body.action)) {
    if (!isUuid(body.registration_id)) return response({ error: "INVALID_REQUEST" }, 400);
    const operation = {
      save_registration: ["staff_update_registration", {
        p_registration_id: body.registration_id, p_full_name: body.full_name,
        p_district_id: body.district_id, p_choices: body.choices,
      }],
      set_import_status: ["staff_set_import_status", {
        p_registration_id: body.registration_id, p_status: body.status,
      }],
      mark_duplicate: ["staff_mark_duplicate", {
        p_registration_id: body.registration_id, p_resolution: body.resolution,
      }],
    }[body.action];
    const { data, error } = await database.rpc(operation[0], { p_actor: profile.auth_user_id, ...operation[1] });
    if (error) {
      if (lostAccess(error)) return lostAccessResponse();
      if (error.message?.includes("DUPLICATE_ALREADY_VOID")) return response({ error: "此紀錄已標記為重複作廢" }, 409);
      // Invalid parameter, bad text, and numeric overflow all come from client input.
      if (["22023", "22P02", "22003"].includes(error.code)) return response({ error: "請檢查資料與活動選擇" }, 400);
      console.error("Failed staff registration operation", error);
      return response({ error: "登記資料更新失敗" }, 503);
    }
    if (!data) return response({ error: "找不到登記紀錄" }, 404);
    return response({ success: true });
  }

  if (body.action === "create_registration") {
    if (!isUuid(body.create_request_id)) return response({ error: "INVALID_REQUEST" }, 400);
    const pepper = queryPepper();
    if (!pepper) return response({ error: "服務暫時無法使用" }, 503);
    const { code, data, error } = await withNewQueryCode(pepper, (codeHash) => database.rpc("staff_create_registration", {
      p_actor: profile.auth_user_id, p_request_id: body.create_request_id,
      p_full_name: body.full_name, p_district_id: body.district_id,
      p_query_code_hash: codeHash, p_choices: body.choices,
    }));
    if (!error && data?.length === 1) return response({ query_code: code, serial_no: data[0].serial_no }, 201);
    if (error?.message?.includes("DUPLICATE_REQUEST")) {
      return response({ error: "此補登已建立；若未取得查詢碼，請在名單中重設查詢碼" }, 409);
    }
    if (lostAccess(error)) return lostAccessResponse();
    if (["22023", "22P02", "22003"].includes(error?.code)) return response({ error: "請檢查登記資料" }, 400);
    console.error("Failed to create staff registration", error);
    return response({ error: "補登失敗，請稍後再試" }, 503);
  }

  if (body.action === "reset_query_code") {
    const serialNo = Number(body.serial_no);
    if (!Number.isSafeInteger(serialNo) || serialNo < 1) return response({ error: "INVALID_REQUEST" }, 400);
    const pepper = queryPepper();
    if (!pepper) return response({ error: "服務暫時無法使用" }, 503);
    const { code, data, error } = await withNewQueryCode(pepper, (codeHash) => database.rpc("staff_reset_query_code", {
      p_actor: profile.auth_user_id, p_serial_no: serialNo, p_query_code_hash: codeHash,
    }));
    if (!error) return data ? response({ query_code: code }) : response({ error: "找不到登記紀錄" }, 404);
    if (lostAccess(error)) return lostAccessResponse();
    console.error("Failed to reset query code", error);
    return response({ error: "查詢碼重設失敗" }, 503);
  }

  if (profile.role !== "admin") return response({ error: "沒有操作權限" }, 403);

  if (body.action === "list_audit") {
    // Password attempt rows exist only for rate limiting; keep them from filling the 100-row view.
    const { data, error } = await database.from("audit_events")
      .select("id,actor_type,action,target_type,created_at")
      .neq("action", "staff.password_verify_attempt")
      .order("id", { ascending: false }).limit(100);
    if (error) {
      console.error("Failed to list audit events", error);
      return response({ error: "稽核紀錄載入失敗" }, 503);
    }
    return response({ events: data });
  }

  if (body.action === "save_reference") {
    if (!["settings", "district", "activity", "program"].includes(body.kind)
      || !body.data || typeof body.data !== "object" || Array.isArray(body.data)) {
      return response({ error: "INVALID_REQUEST" }, 400);
    }
    const { data, error } = await database.rpc("staff_save_reference", {
      p_actor: profile.auth_user_id, p_kind: body.kind, p_data: body.data,
    });
    if (error) {
      if (lostAccess(error)) return lostAccessResponse();
      if (error.code === "23505") return response({ error: "名稱已存在" }, 409);
      // Invalid parameter, check, not-null, bad text, bad date/time, and numeric overflow are all input errors.
      if (["22023", "23514", "23502", "22P02", "22007", "22008", "22003"].includes(error.code)) {
        return response({ error: "請檢查設定內容" }, 400);
      }
      console.error("Failed to save reference data", error);
      return response({ error: "設定儲存失敗" }, 503);
    }
    return response({ saved: data });
  }

  if (body.action === "list_staff") {
    const { data, error } = await database.from("staff_profiles")
      .select("auth_user_id,username,display_name,district_id,role,is_active,must_change_password,created_at")
      .order("created_at");
    if (error) {
      console.error("Failed to list staff", error);
      return response({ error: "帳號載入失敗" }, 503);
    }
    return response({ staff: data });
  }

  if (body.action === "create_staff") {
    const username = String(body.username ?? "").toLowerCase();
    const displayName = String(body.display_name ?? "").trim();
    if (!validUsername(username) || !displayName || displayName.length > 100 || !["admin", "staff"].includes(body.role)) {
      return response({ error: "請檢查帳號資料" }, 400);
    }
    const districtId = body.district_id ?? null;
    if (districtId !== null) {
      // Checked before the Auth user exists, so a bad id never forces a rollback.
      if (!Number.isSafeInteger(districtId)) return response({ error: "請檢查帳號資料" }, 400);
      const { data: district, error: districtError } = await database.from("districts")
        .select("id").eq("id", districtId).maybeSingle();
      if (districtError) {
        console.error("Failed to check staff district", districtError);
        return response({ error: "帳號建立失敗" }, 503);
      }
      if (!district) return response({ error: "請檢查帳號資料" }, 400);
    }
    const { data: existing, error: existingError } = await database.from("staff_profiles")
      .select("auth_user_id").eq("username", username).maybeSingle();
    if (existingError) {
      console.error("Failed to check staff username", existingError);
      return response({ error: "帳號建立失敗" }, 503);
    }
    if (existing) return response({ error: "帳號名稱已被使用" }, 409);
    const password = crypto.randomUUID().replaceAll("-", "");
    const { data: created, error: createError } = await database.auth.admin.createUser({
      email: `${username}@accounts.invalid`, password, email_confirm: true,
    });
    if (createError?.code === "email_exists") {
      // Recheck: another admin may have just created the same name, which is not a leftover.
      const { data: raced } = await database.from("staff_profiles")
        .select("auth_user_id").eq("username", username).maybeSingle();
      if (raced) return response({ error: "帳號名稱已被使用" }, 409);
      console.error("Auth user exists without staff profile", username);
      return response({ error: "帳號名稱已被使用；若名單中沒有此帳號，請聯絡維護人員清除" }, 409);
    }
    if (createError || !created.user) {
      console.error("Failed to create Auth user", createError);
      return response({ error: "帳號建立失敗" }, 503);
    }
    const { error: profileCreateError } = await database.rpc("staff_create_profile", {
      p_actor: profile.auth_user_id,
      p_user_id: created.user.id,
      p_username: username,
      p_display_name: displayName,
      p_role: body.role,
      p_district_id: districtId,
    });
    if (profileCreateError) {
      console.error("Failed to create staff profile", profileCreateError);
      const { error: rollbackError } = await database.auth.admin.deleteUser(created.user.id);
      if (rollbackError) {
        console.error("Failed to roll back Auth user; manual cleanup needed", created.user.id, rollbackError);
        return response({ error: "帳號建立失敗，且需由維護人員清除未完成的帳號" }, 503);
      }
      if (lostAccess(profileCreateError)) return lostAccessResponse();
      return response({ error: "帳號建立失敗" }, 503);
    }
    return response({ password }, 201);
  }

  if (body.action === "reset_staff_password") {
    if (!isUuid(body.user_id)) return response({ error: "INVALID_REQUEST" }, 400);
    // A self reset would end the caller's session before the one-time password could be read.
    if (body.user_id === profile.auth_user_id) {
      return response({ error: "不能重設自己的密碼，請由其他管理員重設" }, 400);
    }
    // Mark first: it confirms the target is staff and ends its sessions before the password changes.
    const { error: profileResetError } = await database.rpc("staff_mark_password_reset", {
      p_actor: profile.auth_user_id, p_user_id: body.user_id,
    });
    if (profileResetError) {
      if (lostAccess(profileResetError)) return lostAccessResponse();
      if (profileResetError.message.includes("STAFF_NOT_FOUND")) return response({ error: "找不到帳號" }, 404);
      console.error("Failed to record staff password reset", profileResetError);
      return response({ error: "密碼重設失敗" }, 503);
    }
    const password = crypto.randomUUID().replaceAll("-", "");
    const { error: resetError } = await database.auth.admin.updateUserById(body.user_id, { password });
    if (resetError) {
      console.error("Failed to reset staff password", resetError);
      return response({ error: "帳號已登出並須更改密碼，但新密碼未設定成功，請再重設一次" }, 503);
    }
    // Revoke again: a sign-in with the old password between the first revoke and the update must not survive.
    const { error: revokeError } = await database.rpc("staff_revoke_sessions", { p_user_id: body.user_id });
    if (revokeError) {
      console.error("Failed to revoke sessions after password reset", revokeError);
      return response({ error: "密碼已重設，但無法確認舊登入已失效，請再重設一次" }, 503);
    }
    return response({ password });
  }

  if (body.action === "set_staff_active") {
    if (!isUuid(body.user_id) || typeof body.is_active !== "boolean") {
      return response({ error: "INVALID_REQUEST" }, 400);
    }
    const { error } = await database.rpc("staff_set_active", {
      p_actor: profile.auth_user_id, p_user_id: body.user_id, p_is_active: body.is_active,
    });
    if (error) {
      if (lostAccess(error)) return lostAccessResponse();
      if (error.message.includes("LAST_ACTIVE_ADMIN")) return response({ error: "不能停用最後一位管理員" }, 409);
      if (error.message.includes("STAFF_NOT_FOUND")) return response({ error: "找不到帳號" }, 404);
      console.error("Failed to change staff active state", error);
      return response({ error: "帳號狀態更新失敗" }, 503);
    }
    return response({ success: true });
  }

  return response({ error: "INVALID_ACTION" }, 400);
}

if (typeof Deno !== "undefined") {
  ({ createClient } = await import("npm:@supabase/supabase-js@2.118.0"));
  Deno.serve(handler);
}
