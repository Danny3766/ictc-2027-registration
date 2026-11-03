import { hashCode, randomCode } from "../supabase/functions/registration/index.ts";

const [command, argument] = process.argv.slice(2);
const url = process.env.SUPABASE_URL;
const secretKey = process.env.SUPABASE_SECRET_KEY;

if (!url || !secretKey) fail("缺少 SUPABASE_URL 或 SUPABASE_SECRET_KEY 環境變數");

let projectUrl;
try {
  projectUrl = new URL(url);
} catch {
  fail("SUPABASE_URL 格式錯誤");
}
if (projectUrl.protocol !== "https:" || !projectUrl.hostname.endsWith(".supabase.co")) {
  fail("為避免 secret 外洩，SUPABASE_URL 必須是 https://*.supabase.co");
}

if (command === "unlock-queries") {
  await rpc("reset_query_protection", {});
  console.log("公開查詢防護已解除，失敗次數已歸零。");
} else if (command === "reset-query-code") {
  const serialNo = Number(String(argument ?? "").replace(/^38-/, ""));
  const pepper = process.env.QUERY_CODE_PEPPER;
  if (!Number.isSafeInteger(serialNo) || serialNo < 1) fail("請提供流水號，例如 38-0001");
  if (!pepper || pepper.length < 32) fail("QUERY_CODE_PEPPER 至少需要 32 個字元");

  const queryCode = randomCode();
  const found = await rpc("reset_registration_query_code", {
    p_serial_no: serialNo,
    p_query_code_hash: await hashCode(queryCode, pepper),
  });
  if (!found) fail("找不到可重設的登記資料");
  console.log(`流水號 38-${String(serialNo).padStart(4, "0")} 的新查詢碼：${queryCode}`);
  console.log("查詢碼只會顯示這一次，請立即安全交付並清除終端機畫面。");
} else {
  fail("用法：node scripts/maintenance.mjs unlock-queries | reset-query-code 38-0001");
}

async function rpc(name, body) {
  const endpoint = new URL(`/rest/v1/rpc/${name}`, projectUrl);
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { apikey: secretKey, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const result = await response.json().catch(() => null);
  if (!response.ok) fail(`維護操作失敗：HTTP ${response.status}`);
  return result;
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
