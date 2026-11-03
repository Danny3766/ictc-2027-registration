import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { startServer } from "./serve-site.mjs";

const server = process.platform === "win32" ? await startServer({
  config: {
    supabaseUrl: "https://test.supabase.co",
    publishableKey: "sb_publishable_test",
    environment: "test",
  },
}) : null;
const cli = new URL("../node_modules/playwright/cli.js", import.meta.url);
const child = spawn(process.execPath, [fileURLToPath(cli), "test", ...process.argv.slice(2)], {
  stdio: "inherit",
  windowsHide: true,
});

const exitCode = await new Promise((resolve) => {
  child.once("exit", (code) => resolve(code ?? 1));
  child.once("error", () => resolve(1));
});
if (server) await new Promise((resolve) => server.close(resolve));
process.exitCode = exitCode;
