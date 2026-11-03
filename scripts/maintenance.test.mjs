import { test } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";

test("query code reset sends only a hash and prints the new code once", async () => {
  const previous = {
    argv: process.argv,
    fetch: globalThis.fetch,
    log: console.log,
    url: process.env.SUPABASE_URL,
    key: process.env.SUPABASE_SECRET_KEY,
    pepper: process.env.QUERY_CODE_PEPPER,
  };
  const logs = [];
  const requests = [];
  try {
    process.argv = [process.execPath, "scripts/maintenance.mjs", "reset-query-code", "38-0001"];
    process.env.SUPABASE_URL = "https://test.supabase.co";
    process.env.SUPABASE_SECRET_KEY = "test-placeholder";
    process.env.QUERY_CODE_PEPPER = "p".repeat(32);
    console.log = (message) => logs.push(message);
    globalThis.fetch = async (url, options) => {
      requests.push({ url: String(url), options });
      return { ok: true, json: async () => true };
    };

    await import(`./maintenance.mjs?test=${Date.now()}`);

    assert.equal(requests.length, 1);
    assert.equal(new URL(requests[0].url).pathname, "/rest/v1/rpc/reset_registration_query_code");
    assert.equal(requests[0].options.headers.apikey, "test-placeholder");
    const body = JSON.parse(requests[0].options.body);
    assert.equal(body.p_serial_no, 1);
    const code = logs[0].match(/新查詢碼：([a-z2-9]{8})/)?.[1];
    assert.ok(code);
    assert.equal(body.p_query_code_hash, createHmac("sha256", "p".repeat(32)).update(code).digest("hex"));
    assert.equal(logs.filter((line) => line.includes(code)).length, 1);
  } finally {
    process.argv = previous.argv;
    globalThis.fetch = previous.fetch;
    console.log = previous.log;
    for (const [name, value] of [["SUPABASE_URL", previous.url], ["SUPABASE_SECRET_KEY", previous.key], ["QUERY_CODE_PEPPER", previous.pepper]]) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  }
});
