import { expect, test } from "@playwright/test";
import { readFile } from "node:fs/promises";

async function mockStaff(page, role, onRequest = () => {}, registrationName = "測試登記", replies = {}) {
  await page.route("**/auth/v1/token?grant_type=password", async (route) => {
    const body = route.request().postDataJSON();
    expect(body.email).toBe("tester@accounts.invalid");
    await route.fulfill({ json: { access_token: "test-access", refresh_token: "test-refresh", expires_in: 3600 } });
  });
  await page.route("**/auth/v1/logout?scope=local", (route) => route.fulfill({ status: 204 }));
  await page.route("**/functions/v1/staff", async (route) => {
    expect(route.request().headers().authorization).toBe("Bearer test-access");
    const payload = route.request().postDataJSON();
    const { action } = payload;
    onRequest(payload);
    const reply = replies[action]?.(payload);
    if (reply) return route.fulfill(reply);
    const result = {
      me: { profile: { auth_user_id: "123e4567-e89b-42d3-a456-426614174000", display_name: "測試服事者", role, must_change_password: false } },
      list_reference: { settings: { event_name: "測試", is_registration_open: false }, districts: [{ id: 1, name: "林森", is_active: true, sort_order: 1 }], activities: [{ id: 1, title: "測試聚會", is_published: true, fee_amount: 0 }], program: [] },
      list_registrations: { count: 1, registrations: [{ id: "223e4567-e89b-42d3-a456-426614174000", serial_no: 1, full_name: registrationName, district_id: 1, record_status: "active", import_status: "pending", duplicate_review_status: "unreviewed", registration_choices: [{ activity_id: 1, attending: false }], updated_at: "2026-11-04T00:00:00Z" }] },
      list_staff: { staff: [] },
      list_audit: { events: [] },
      save_registration: { success: true },
      save_reference: { saved: {} },
    }[action];
    await route.fulfill({ status: result ? 200 : 400, json: result ?? { error: "INVALID_ACTION" } });
  });
}

test("staff registration edit sends all published activity choices", async ({ page }) => {
  let saved;
  await mockStaff(page, "staff", (payload) => { if (payload.action === "save_registration") saved = payload; });
  await page.goto("/admin/");
  await page.locator('#login-form input[name="username"]').fill("tester");
  await page.locator('#login-form input[name="password"]').fill("test-password");
  await page.getByRole("button", { name: "登入" }).click();
  await page.getByRole("button", { name: "查看／處理" }).click();
  await page.locator('#edit-registration-form input[name="full_name"]').fill("修改後姓名");
  await page.locator('#edit-registration-form input[name="activity_1"][value="true"]').check();
  await page.getByRole("button", { name: "儲存登記" }).click();
  await expect(page.locator("#message")).toHaveText("登記資料已儲存。");
  expect(saved.registration_id).toBe("223e4567-e89b-42d3-a456-426614174000");
  expect(saved.choices).toEqual([{ activity_id: 1, attending: true }]);
});

test("CSV neutralizes spreadsheet formulas and omits query codes", async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== "desktop-chromium");
  await mockStaff(page, "staff", () => {}, "=1+1");
  await page.goto("/admin/");
  await page.locator('#login-form input[name="username"]').fill("tester");
  await page.locator('#login-form input[name="password"]').fill("test-password");
  await page.getByRole("button", { name: "登入" }).click();
  const download = page.waitForEvent("download");
  await page.getByRole("button", { name: "下載 CSV" }).click();
  const csv = await readFile(await (await download).path(), "utf8");
  expect(csv).toContain("'\u003d1+1");
  expect(csv).not.toContain("query_code");
});

for (const role of ["staff", "admin"]) {
  test(`${role} login loads only its permitted back-office sections`, async ({ page }) => {
    await mockStaff(page, role);
    await page.goto("/admin/");
    await page.locator("#login-form").getByLabel("帳號", { exact: true }).fill("tester");
    await page.locator("#login-form").getByLabel("密碼", { exact: true }).fill("test-password");
    await page.getByRole("button", { name: "登入" }).click();
    await expect(page.getByText("測試登記")).toBeVisible();
    await expect(page.locator("#login-panel")).toBeHidden();
    if (role === "admin") await expect(page.locator("#admin-accounts")).toBeVisible();
    else await expect(page.locator("#admin-accounts")).toBeHidden();
    await expect(page.locator('#new-registration-form select[name="district_id"] option')).toHaveCount(2);
    await expect(page.locator('#new-registration-choices input[name="activity_1"]')).toHaveCount(2);
    await page.getByRole("button", { name: "登出" }).click();
    await expect(page.locator("#staff-panel")).toBeHidden();
    await expect(page.locator("#admin-accounts")).toBeHidden();
    await expect(page.locator("#registration-rows tr")).toHaveCount(0);
  });
}

async function login(page) {
  await page.goto("/admin/");
  await page.locator('#login-form input[name="username"]').fill("tester");
  await page.locator('#login-form input[name="password"]').fill("test-password");
  await page.getByRole("button", { name: "登入" }).click();
}

test("saving an edited district leaves the form ready to create a new one", async ({ page }) => {
  const saved = [];
  await mockStaff(page, "admin", (payload) => { if (payload.action === "save_reference") saved.push(payload.data); });
  await login(page);
  await page.locator("#district-rows").getByRole("button", { name: "編輯" }).click();
  await page.getByRole("button", { name: "儲存區選項" }).click();
  await expect(page.locator("#message")).toHaveText("設定已儲存。");
  await page.locator('#district-form input[name="name"]').fill("新區");
  await page.locator('#district-form input[name="sort_order"]').fill("9");
  await page.getByRole("button", { name: "儲存區選項" }).click();
  await expect.poll(() => saved.length).toBe(2);
  expect(saved[0].id).toBe("1");
  expect(saved[1].id).toBeUndefined();
});

test("cancelling an edit makes the next save create a new row", async ({ page }) => {
  const saved = [];
  await mockStaff(page, "admin", (payload) => { if (payload.action === "save_reference") saved.push(payload.data); });
  await login(page);
  const form = page.locator("#district-form");
  await page.locator("#district-rows").getByRole("button", { name: "編輯" }).click();
  await expect(form.locator('button[type="submit"]')).toHaveText("儲存區選項（編輯：林森）");
  await form.getByRole("button", { name: "取消編輯" }).click();
  await expect(form.locator('button[type="submit"]')).toHaveText("儲存區選項");
  await form.locator('input[name="name"]').fill("新區");
  await form.locator('input[name="sort_order"]').fill("9");
  await form.locator('button[type="submit"]').click();
  await expect.poll(() => saved.length).toBe(1);
  expect(saved[0].id).toBeUndefined();
  expect(saved[0].name).toBe("新區");
});

test("a temporary back-office outage on reload keeps the login", async ({ page }) => {
  let outage = false;
  await mockStaff(page, "staff", () => {}, "測試登記", {
    list_reference: () => (outage ? { status: 503, json: { error: "後台資料載入失敗" } } : undefined),
  });
  await login(page);
  await expect(page.getByText("測試登記")).toBeVisible();
  outage = true;
  await page.reload();
  await expect(page.locator("#message")).toHaveText("後台資料載入失敗");
  expect(await page.evaluate(() => sessionStorage.getItem("ictc_staff_session"))).not.toBeNull();
});

test("retrying a failed back-office registration reuses its request id", async ({ page }) => {
  const ids = [];
  await mockStaff(page, "staff", () => {}, "測試登記", {
    create_registration: (payload) => {
      ids.push(payload.create_request_id);
      return ids.length === 1 ? { status: 503, json: { error: "補登失敗，請稍後再試" } }
        : { status: 201, json: { query_code: "abcd2345", serial_no: 2 } };
    },
  });
  await login(page);
  const form = page.locator("#new-registration-form");
  await form.locator('input[name="full_name"]').fill("補登測試");
  await form.locator('select[name="district_id"]').selectOption("1");
  await form.locator('input[name="activity_1"][value="true"]').check();
  await form.getByRole("button", { name: "建立補登" }).click();
  await expect(page.locator("#message")).toHaveText("補登失敗，請稍後再試");
  await form.getByRole("button", { name: "建立補登" }).click();
  await expect(page.locator("#new-registration-code")).toContainText("abcd2345");
  expect(ids).toHaveLength(2);
  expect(ids[1]).toBe(ids[0]);
});

test("admins cannot reset their own password from the account list", async ({ page }) => {
  const self = "123e4567-e89b-42d3-a456-426614174000";
  await mockStaff(page, "admin", () => {}, "測試登記", {
    list_staff: () => ({ json: { staff: [
      { auth_user_id: self, username: "tester", display_name: "測試服事者", role: "admin", is_active: true },
      { auth_user_id: "323e4567-e89b-42d3-a456-426614174000", username: "other", display_name: "其他", role: "staff", is_active: true },
    ] } }),
  });
  await login(page);
  const rows = page.locator("#staff-rows tr");
  await expect(rows).toHaveCount(2);
  await expect(rows.nth(0).getByRole("button", { name: "重設密碼" })).toHaveCount(0);
  await expect(rows.nth(1).getByRole("button", { name: "重設密碼" })).toHaveCount(1);
});

test("a token refresh keeps the login on an Auth outage and ends it when rejected", async ({ page }) => {
  await mockStaff(page, "staff");
  // Expires within the 60s refresh margin, so the first back-office call refreshes the token.
  await page.route("**/auth/v1/token?grant_type=password", (route) =>
    route.fulfill({ json: { access_token: "test-access", refresh_token: "test-refresh", expires_in: 30 } }));
  let refreshStatus = 503;
  await page.route("**/auth/v1/token?grant_type=refresh_token", (route) => route.fulfill({ status: refreshStatus, json: {} }));
  await login(page);
  await expect(page.locator("#message")).toHaveText("暫時無法連線，請稍後再試");
  expect(await page.evaluate(() => sessionStorage.getItem("ictc_staff_session"))).not.toBeNull();
  refreshStatus = 400;
  await page.reload();
  await expect(page.locator("#message")).toHaveText("登入已過期，請重新登入");
  expect(await page.evaluate(() => sessionStorage.getItem("ictc_staff_session"))).toBeNull();
});

const twoActivities = {
  list_reference: () => ({ json: {
    settings: { event_name: "測試", is_registration_open: false },
    districts: [{ id: 1, name: "林森", is_active: true, sort_order: 1 }],
    activities: [{ id: 1, title: "測試聚會", is_published: true, fee_amount: 0 }, { id: 2, title: "新增活動", is_published: true, fee_amount: 100 }],
    program: [],
  } }),
};

test("editing an old registration leaves a newer activity unanswered", async ({ page }) => {
  let saved;
  await mockStaff(page, "staff", (payload) => { if (payload.action === "save_registration") saved = payload; }, "測試登記", twoActivities);
  await login(page);
  await page.getByRole("button", { name: "查看／處理" }).click();
  await expect(page.locator("#detail-choices")).toContainText("（未回覆，可留空）");
  await page.locator('#edit-registration-form input[name="full_name"]').fill("修改後姓名");
  await page.getByRole("button", { name: "儲存登記" }).click();
  await expect(page.locator("#message")).toHaveText("登記資料已儲存。");
  expect(saved.choices).toEqual([{ activity_id: 1, attending: false }]);
});

test("statistics break down answers by district and activity", async ({ page }) => {
  await mockStaff(page, "staff", () => {}, "測試登記", twoActivities);
  await login(page);
  await page.getByRole("button", { name: "更新統計" }).click();
  const rows = page.locator("#district-activity-stats-rows tr");
  await expect(rows).toHaveCount(2);
  await expect(rows.nth(0).locator("td")).toHaveText(["林森", "測試聚會", "0", "1", "0"]);
  await expect(rows.nth(1).locator("td")).toHaveText(["林森", "新增活動", "0", "0", "1"]);
});
