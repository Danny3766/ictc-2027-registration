import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  use: { baseURL: "http://127.0.0.1:8765" },
  projects: [
    { name: "desktop-chromium", use: { ...devices["Desktop Chrome"] } },
    { name: "desktop-webkit", use: { ...devices["Desktop Safari"] } },
    { name: "mobile-chrome", use: { ...devices["Pixel 7"] } },
    { name: "mobile-safari", use: { ...devices["iPhone 13"] } },
  ],
  webServer: {
    command: "python -m http.server 8765 --bind 127.0.0.1 --directory site",
    url: "http://127.0.0.1:8765/",
    reuseExistingServer: true,
  },
});
