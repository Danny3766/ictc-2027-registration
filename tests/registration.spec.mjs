import { expect, test } from "@playwright/test";

test("建立、查詢、修改、取消與恢復登記", async ({ page }) => {
  const name = `自動測試 ${Date.now()}`;
  await page.goto("/");
  await expect(page.getByRole("button", { name: "送出登記" })).toBeEnabled();
  await page.locator('#registration-form input[name="full_name"]').fill(name);
  await page.locator('#registration-form select[name="district_id"]').selectOption("1");
  await page.locator('#registration-form input[name="activity_1"][value="true"]').check();
  await page.locator('#registration-form input[name="activity_2"][value="false"]').check();
  await page.getByRole("button", { name: "送出登記" }).click();

  await expect(page).toHaveURL(/success\.html$/);
  const code = await page.locator("#query-code").innerText();
  expect(code).toMatch(/^[a-hjkmnp-z2-9]{5}$/);
  await page.locator("#saved-confirmation").check();
  await page.locator("#back-link").click();

  await page.locator('#query-form input[name="query_code"]').fill(code);
  await page.getByRole("button", { name: "查詢" }).click();
  await expect(page.locator('#edit-form input[name="full_name"]')).toHaveValue(name);

  await page.locator('#edit-form input[name="full_name"]').fill(`${name} 修改`);
  await page.getByRole("button", { name: "儲存修改" }).click();
  await expect(page.locator("#page-message")).toContainText("已更新");
  await page.getByRole("button", { name: "查詢" }).click();
  await expect(page.locator('#edit-form input[name="full_name"]')).toHaveValue(`${name} 修改`);

  await page.getByRole("button", { name: "取消登記" }).click();
  await expect(page.locator("#page-message")).toContainText("已取消");
  await page.getByRole("button", { name: "查詢" }).click();
  await expect(page.getByRole("button", { name: "恢復登記" })).toBeVisible();
  await page.getByRole("button", { name: "恢復登記" }).click();
  await expect(page.locator("#page-message")).toContainText("已恢復");
  await page.getByRole("button", { name: "查詢" }).click();
  await expect(page.getByRole("button", { name: "取消登記" })).toBeVisible();
});
