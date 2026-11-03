import { expect, test } from "@playwright/test";

test.skip(process.env.RUN_LIVE_REGISTRATION_TEST !== "1", "Creates a remote registration; run only with test-data cleanup ready.");

test("建立、查詢與儲存登記", async ({ page }) => {
  const name = `自動測試 ${Date.now()}`;
  await page.goto("/");
  await expect(page.getByRole("button", { name: "送出登記" })).toBeEnabled();
  await page.locator('#registration-form input[name="full_name"]').fill(name);
  await page.locator('#registration-form select[name="district_id"]').selectOption("1");
  for (const activity of await page.locator("#registration-form .activity").all()) {
    await activity.locator('input[value="false"]').check();
  }
  await page.getByRole("button", { name: "送出登記" }).click();

  await expect(page).toHaveURL(/success\.html$/);
  const code = await page.locator("#query-code").innerText();
  expect(code).toMatch(/^[a-hjkmnp-z2-9]{8}$/);
  await page.locator("#saved-confirmation").check();
  await page.locator("#back-link").click();

  await page.getByRole("tab", { name: "查詢或修改登記" }).click();
  await page.locator('#query-form input[name="query_code"]').fill(code);
  await page.getByRole("button", { name: "查詢" }).click();
  await expect(page.locator('#edit-form input[name="full_name"]')).toHaveValue(name);

  await page.locator('#edit-form input[name="full_name"]').fill(`${name} 修改`);
  await page.getByRole("button", { name: "儲存", exact: true }).click();
  await expect(page.locator("#page-message")).toHaveText("登記資料已儲存。");
  await page.getByRole("button", { name: "查詢" }).click();
  await expect(page.locator('#edit-form input[name="full_name"]')).toHaveValue(`${name} 修改`);
  await expect(page.locator("#edit-form button")).toHaveCount(1);
});
