import { writeFileSync } from "node:fs";

const supabaseUrl = process.env.SUPABASE_URL;
const publishableKey = process.env.SUPABASE_PUBLISHABLE_KEY;
if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(supabaseUrl ?? "") || !/^sb_publishable_/.test(publishableKey ?? "")) {
  throw new Error("缺少有效的 GitHub Pages 公開 Supabase 設定");
}

writeFileSync("site/config.js", `window.APP_CONFIG = ${JSON.stringify({ supabaseUrl, publishableKey, environment: process.env.SITE_ENVIRONMENT })};\n`);
