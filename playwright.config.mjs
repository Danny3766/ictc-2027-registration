import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  use: { baseURL: "http://127.0.0.1:8765", browserName: "chromium" },
  webServer: {
    command: "python -m http.server 8765 --bind 127.0.0.1 --directory site",
    url: "http://127.0.0.1:8765/",
    reuseExistingServer: true,
  },
});
