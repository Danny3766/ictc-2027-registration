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
      list_reference: { settings: { event_name: "測試", is_registration_open: false }, districts: [{ id: 1, name: "林森", sort_order: 1 }], activities: [{ id: 1, title: "測試聚會", is_published: true, fee_amount: 0 }], program: [] },
      list_registrations: { count: 1, registrations: [{ id: "223e4567-e89b-42d3-a456-426614174000", serial_no: 1, full_name: registrationName, district_id: 1, record_status: "active", import_status: "pending", registration_choices: [{ activity_id: 1, attending: false }], updated_at: "2026-11-04T00:00:00Z" }] },
      list_staff: { staff: [] },
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

test("CSV neutralizes spreadsheet formulas", async ({ page }, testInfo) => {
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
  expect(csv).toContain('"待匯入"');
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

test("activity sort is preserved when editing and defaults to the end when creating", async ({ page }) => {
  const saved = [];
  await mockStaff(page, "admin", (payload) => { if (payload.action === "save_reference") saved.push(payload.data); }, "測試登記", threeActivities);
  await login(page);
  await page.locator("#activity-rows").getByRole("button", { name: "編輯" }).first().click();
  await page.locator('#activity-form input[name="sort_order"]').fill("");
  await page.locator("#activity-form").getByRole("button", { name: /^儲存活動/ }).click();
  await expect(page.locator("#message")).toHaveText("設定已儲存。");
  await page.locator('#activity-form input[name="title"]').fill("新活動");
  await page.getByRole("button", { name: "儲存活動" }).click();
  await expect.poll(() => saved.length).toBe(2);
  expect(saved[0].id).toBe("1");
  expect(saved[0].sort_order).toBe(1);
  expect(saved[1].id).toBeUndefined();
  expect(saved[1].sort_order).toBe(4);
});

test("activity dates allow an optional Taiwan time", async ({ page }) => {
  let saved;
  await mockStaff(page, "admin", (payload) => { if (payload.action === "save_reference") saved = payload.data; }, "測試登記", {
    list_reference: () => ({ json: {
      settings: { event_name: "測試", is_registration_open: false },
      districts: [{ id: 1, name: "林森", sort_order: 1 }],
      activities: [{
        id: 1, title: "日期活動", category: "meeting", starts_at: "2027-02-20T00:00:00+08:00",
        starts_at_has_time: false, ends_at: null, ends_at_has_time: false, is_published: true, sort_order: 1,
      }],
      program: [],
    } }),
  });
  await login(page);
  await expect(page.locator("#activity-rows tr").first()).toContainText("2/20");
  await expect(page.locator("#activity-rows tr").first()).not.toContainText("00:00");
  await page.locator("#activity-rows").getByRole("button", { name: "編輯" }).click();
  const form = page.locator("#activity-form");
  await expect(form.locator('input[name="starts_on"]')).toHaveValue("2027-02-20");
  await expect(form.locator('input[name="starts_time"]')).toHaveValue("");
  await form.locator('input[name="starts_time"]').fill("12:30");
  await form.getByRole("button", { name: /^儲存活動/ }).click();
  await expect.poll(() => saved).toBeTruthy();
  expect(saved.starts_at).toBe("2027-02-20T12:30:00+08:00");
  expect(saved.starts_at_has_time).toBe(true);
  expect(saved.ends_at).toBeNull();
  expect(saved.ends_at_has_time).toBe(false);
});

test("cancelling an edit makes the next save create a new row", async ({ page }) => {
  const saved = [];
  await mockStaff(page, "admin", (payload) => { if (payload.action === "save_reference") saved.push(payload.data); }, "測試登記", threeActivities);
  await login(page);
  const form = page.locator("#activity-form");
  await page.locator("#activity-rows").getByRole("button", { name: "編輯" }).first().click();
  await expect(form.locator('button[type="submit"]')).toHaveText("儲存活動（編輯：活動甲）");
  await form.getByRole("button", { name: "取消編輯" }).click();
  await expect(form.locator('button[type="submit"]')).toHaveText("儲存活動");
  await form.locator('input[name="title"]').fill("新活動");
  await form.locator('input[name="sort_order"]').fill("9");
  await form.locator('button[type="submit"]').click();
  await expect.poll(() => saved.length).toBe(1);
  expect(saved[0].id).toBeUndefined();
  expect(saved[0].title).toBe("新活動");
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
        : { status: 201, json: { serial_no: 2 } };
    },
  });
  await login(page);
  const form = page.locator("#new-registration-form");
  await form.locator('input[name="full_name"]').fill("補登測試");
  await form.locator('select[name="district_id"]').selectOption("1");
  await form.locator('input[name="activity_1"][value="true"]').check();
  await form.locator('input[name="hosting_status"][value="not_hosting"]').check();
  await form.getByRole("button", { name: "建立補登" }).click();
  await expect(page.locator("#message")).toHaveText("補登失敗，請稍後再試");
  await form.getByRole("button", { name: "建立補登" }).click();
  await expect(page.locator("#new-registration-code")).toHaveText("已建立流水號 2。本人日後可用相同的姓名與區查詢。");
  expect(ids).toHaveLength(2);
  expect(ids[1]).toBe(ids[0]);
});

const self = "123e4567-e89b-42d3-a456-426614174000";
const other = "323e4567-e89b-42d3-a456-426614174000";
const twoAccounts = () => ({ json: { staff: [
  { auth_user_id: self, username: "tester", display_name: "測試服事者", role: "admin", is_active: true },
  { auth_user_id: other, username: "other", display_name: "其他", role: "staff", is_active: true },
] } });

test("admins set another account's password, but change their own with the current one", async ({ page }) => {
  const sent = [];
  await mockStaff(page, "admin", (payload) => { if (payload.action === "set_staff_password") sent.push(payload); }, "測試登記", {
    list_staff: twoAccounts,
    set_staff_password: () => ({ json: { success: true } }),
  });
  page.on("dialog", (dialog) => dialog.accept());
  await login(page);
  const rows = page.locator("#staff-rows tr");
  await expect(rows).toHaveCount(2);
  await expect(page.getByRole("button", { name: "重設密碼" })).toHaveCount(0);

  await rows.nth(0).getByRole("button", { name: "修改" }).click();
  await expect(page.locator("#staff-password-form")).toBeHidden();
  await expect(page.locator("#staff-password-self")).toBeVisible();

  await rows.nth(1).getByRole("button", { name: "修改" }).click();
  const passwordForm = page.locator("#staff-password-form");
  await expect(passwordForm).toBeVisible();
  await passwordForm.locator('input[name="password"]').fill("short");
  await passwordForm.getByRole("button", { name: "設定密碼" }).click();
  expect(sent).toHaveLength(0);
  await passwordForm.locator('input[name="password"]').fill("new-staff-password-1");
  await passwordForm.getByRole("button", { name: "設定密碼" }).click();
  await expect(page.locator("#message")).toHaveText("密碼已設定。請以安全方式私下交付。");
  expect(sent).toEqual([{ action: "set_staff_password", user_id: other, password: "new-staff-password-1" }]);
  await expect(passwordForm.locator('input[name="password"]')).toHaveValue("");
});

test("admins create accounts with a password and no district, and rename them", async ({ page }) => {
  const sent = [];
  await mockStaff(page, "admin", (payload) => { if (["create_staff", "update_staff"].includes(payload.action)) sent.push(payload); }, "測試登記", {
    list_staff: twoAccounts,
    create_staff: () => ({ status: 201, json: { success: true } }),
    update_staff: () => ({ json: { success: true } }),
  });
  await login(page);
  const create = page.locator("#create-staff-form");
  await expect(create.locator('select[name="district_id"]')).toHaveCount(0);
  await create.locator('input[name="username"]').fill("newhelper");
  await create.locator('input[name="display_name"]').fill("新服事者");
  await create.locator('input[name="password"]').fill("new-staff-password-1");
  await create.getByRole("button", { name: "建立帳號" }).click();
  await expect(page.locator("#message")).toHaveText("帳號已建立。請以安全方式私下交付密碼。");
  expect(sent[0]).toEqual({ action: "create_staff", username: "newhelper", display_name: "新服事者", role: "staff", password: "new-staff-password-1" });
  await expect(create.locator('input[name="password"]')).toHaveValue("");

  await page.locator("#staff-rows tr").nth(1).getByRole("button", { name: "修改" }).click();
  const edit = page.locator("#edit-staff-form");
  await expect(edit.locator('input[name="username"]')).toHaveValue("other");
  await edit.locator('input[name="username"]').fill("renamed");
  await edit.locator('input[name="display_name"]').fill("改名後");
  await edit.getByRole("button", { name: "儲存帳號" }).click();
  await expect(page.locator("#message")).toHaveText("帳號已更新，之後請用新帳號名稱登入。");
  expect(sent[1]).toEqual({ action: "update_staff", user_id: other, username: "renamed", display_name: "改名後" });
  await page.getByRole("button", { name: "關閉", exact: true }).click();
  await expect(page.locator("#staff-editor")).toBeHidden();
});

test("anyone signed in can change their own password from the navigation", async ({ page }) => {
  let sent;
  await mockStaff(page, "staff", (payload) => { if (payload.action === "change_password") sent = payload; }, "測試登記", {
    change_password: () => ({ json: { success: true } }),
  });
  await login(page);
  await expect(page.locator("#change-password-panel")).toBeHidden();
  await page.locator(".staff-nav").getByRole("button", { name: "更改密碼" }).click();
  const panel = page.locator("#change-password-panel");
  await expect(panel).toBeVisible();
  await expect(panel.locator("h2")).toHaveText("更改密碼");
  await panel.getByRole("button", { name: "取消" }).click();
  await expect(panel).toBeHidden();

  await page.locator(".staff-nav").getByRole("button", { name: "更改密碼" }).click();
  await panel.locator('input[name="current_password"]').fill("old-test-password-1");
  await panel.locator('input[name="password"]').fill("new-test-password-1");
  await panel.locator('button[type="submit"]').click();
  await expect(page.locator("#message")).toHaveText("密碼已更改，請使用新密碼重新登入。");
  expect(sent).toEqual({ action: "change_password", current_password: "old-test-password-1", password: "new-test-password-1" });
  await expect(page.locator("#login-panel")).toBeVisible();
  await expect(page.locator("#staff-panel")).toBeHidden();
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
    districts: [{ id: 1, name: "林森", sort_order: 1 }],
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

test("voiding a registration requires a reason and sends it", async ({ page }) => {
  let voided;
  await mockStaff(page, "staff", (payload) => { if (payload.action === "void_registration") voided = payload; }, "測試登記", {
    void_registration: () => ({ json: { success: true } }),
  });
  page.on("dialog", (dialog) => dialog.accept());
  await login(page);
  await page.getByRole("button", { name: "查看／處理" }).click();
  const form = page.locator("#void-form");
  await form.getByRole("button", { name: "作廢此登記" }).click();
  expect(voided).toBeUndefined();
  await form.locator('input[name="reason"]').fill("  填錯了  ");
  await form.getByRole("button", { name: "作廢此登記" }).click();
  await expect(page.locator("#message")).toHaveText("登記已作廢。");
  expect(voided).toEqual({ action: "void_registration", registration_id: "223e4567-e89b-42d3-a456-426614174000", reason: "填錯了" });
});

test("a message from before login is cleared once login succeeds", async ({ page }) => {
  await mockStaff(page, "staff");
  await page.goto("/admin/");
  await page.locator('#login-form input[name="username"]').fill("X");
  await page.locator('#login-form input[name="password"]').fill("test-password");
  await page.getByRole("button", { name: "登入" }).click();
  await expect(page.locator("#message")).toHaveText("請檢查帳號格式");
  await page.locator('#login-form input[name="username"]').fill("tester");
  await page.locator('#login-form input[name="password"]').fill("test-password");
  await page.getByRole("button", { name: "登入" }).click();
  await expect(page.getByText("測試登記")).toBeVisible();
  await expect(page.locator("#message")).toBeHidden();
});

test("admin layout fits phones, tablets and desktops without page-level horizontal scrolling", async ({ page }) => {
  await mockStaff(page, "admin");
  await login(page);
  await expect(page.getByText("測試登記")).toBeVisible();
  for (const width of [360, 390, 768, 1024, 1366, 1920]) {
    await page.setViewportSize({ width, height: 900 });
    expect(await page.evaluate(() => document.documentElement.scrollWidth), `${width}px page overflow`).toBeLessThanOrEqual(width);
    await expect(page.locator(".staff-nav")).toBeVisible();
    const logout = await page.getByRole("button", { name: "登出" }).boundingBox();
    expect(logout.x + logout.width, `${width}px logout inside viewport`).toBeLessThanOrEqual(width);
    // Wide tables scroll inside their own box instead of widening the page.
    for (const box of await page.locator(".table-scroll").all()) {
      const { right } = await box.evaluate((element) => element.getBoundingClientRect());
      expect(right, `${width}px table box inside viewport`).toBeLessThanOrEqual(width);
    }
    // Check boxes and row buttons keep their natural size instead of the public form's full width.
    const radio = await page.locator('#new-registration-choices input[type="radio"]').first().boundingBox();
    expect(radio.width, `${width}px radio size`).toBeLessThan(32);
    const rowButton = await page.getByRole("button", { name: "查看／處理" }).first().boundingBox();
    expect(rowButton.width, `${width}px row button size`).toBeLessThan(160);
  }
});

const threeActivities = {
  list_reference: () => ({ json: {
    settings: { event_name: "測試", is_registration_open: false },
    districts: [{ id: 1, name: "林森", sort_order: 1 }],
    activities: [
      { id: 1, title: "活動甲", category: "meeting", is_published: true, sort_order: 1 },
      { id: 2, title: "活動乙", category: "meal", is_published: true, sort_order: 2 },
      { id: 3, title: "活動丙", category: "other", is_published: true, sort_order: 3 },
    ],
    program: [],
  } }),
};
const activityTitles = (page) => page.locator("#activity-rows tr td:first-child").allTextContents();

test("activities can be reordered by dragging or arrow keys and saved together", async ({ page }) => {
  let saved;
  await mockStaff(page, "admin", (payload) => { if (payload.action === "reorder_activities") saved = payload; }, "測試登記", {
    ...threeActivities,
    reorder_activities: () => ({ json: { success: true } }),
  });
  await login(page);
  const handles = page.locator("#activity-rows .drag-handle");
  await expect(handles.first()).toBeHidden();
  await page.getByRole("button", { name: "調整排序" }).click();
  await expect(handles.first()).toBeVisible();
  // The handle must be on screen without scrolling the table sideways, including on phones.
  const handleBox = await handles.first().boundingBox();
  expect(handleBox.x + handleBox.width).toBeLessThanOrEqual(page.viewportSize().width);
  // On phones the edit column is hidden while reordering, so check the button itself, not by role.
  await expect(page.locator("#activity-rows button:not(.drag-handle)").first()).toBeDisabled();

  await handles.nth(0).focus();
  await page.keyboard.press("ArrowDown");
  expect(await activityTitles(page)).toEqual(["活動乙", "活動甲", "活動丙"]);

  // Drag 活動丙 above the first row with pointer moves. Center the table first so the sticky
  // navigation bar does not cover the rows.
  await page.locator("#activity-rows").evaluate((element) => element.scrollIntoView({ block: "center" }));
  const from = await handles.nth(2).boundingBox();
  const to = await page.locator("#activity-rows tr").first().boundingBox();
  await page.mouse.move(from.x + from.width / 2, from.y + from.height / 2);
  await page.mouse.down();
  await page.mouse.move(from.x + from.width / 2, to.y + 4, { steps: 8 });
  await page.mouse.up();
  expect(await activityTitles(page)).toEqual(["活動丙", "活動乙", "活動甲"]);

  await page.getByRole("button", { name: "完成排序" }).click();
  await expect(page.locator("#message")).toHaveText("活動排序已儲存。");
  expect(saved.activity_ids).toEqual([3, 2, 1]);
  await expect(page.getByRole("button", { name: "調整排序" })).toBeVisible();
});

test("cancelling a reorder restores the order without saving", async ({ page }) => {
  let saved = false;
  await mockStaff(page, "admin", (payload) => { if (payload.action === "reorder_activities") saved = true; }, "測試登記", threeActivities);
  await login(page);
  await page.getByRole("button", { name: "調整排序" }).click();
  await page.locator("#activity-rows .drag-handle").first().focus();
  await page.keyboard.press("ArrowDown");
  await page.getByRole("button", { name: "取消", exact: true }).click();
  expect(await activityTitles(page)).toEqual(["活動甲", "活動乙", "活動丙"]);
  await expect(page.locator("#activity-rows .drag-handle").first()).toBeHidden();
  expect(saved).toBe(false);
});

test("saving a reorder updates the sort order of an activity edit that is already open", async ({ page }) => {
  await mockStaff(page, "admin", () => {}, "測試登記", { ...threeActivities, reorder_activities: () => ({ json: { success: true } }) });
  await login(page);
  await page.locator("#activity-rows tr").first().getByRole("button", { name: "編輯" }).click();
  await expect(page.locator('#activity-form input[name="sort_order"]')).toHaveValue("1");
  await page.getByRole("button", { name: "調整排序" }).click();
  await page.locator("#activity-rows .drag-handle").first().focus();
  await page.keyboard.press("ArrowDown");
  await page.getByRole("button", { name: "完成排序" }).click();
  await expect(page.locator("#message")).toHaveText("活動排序已儲存。");
  await expect(page.locator('#activity-form input[name="sort_order"]')).toHaveValue("2");
});


test("while reordering, settings still save and keep the drag order, activities wait, and cancelling keeps 補登 input", async ({ page }) => {
  const saves = [];
  await mockStaff(page, "admin", (payload) => { if (payload.action === "save_reference") saves.push(payload.kind); }, "測試登記", threeActivities);
  await login(page);
  const newForm = page.locator("#new-registration-form");
  await newForm.locator('input[name="full_name"]').fill("補登測試");
  await newForm.locator('select[name="district_id"]').selectOption("1");
  await newForm.locator('input[name="activity_2"][value="true"]').check();

  await page.getByRole("button", { name: "調整排序" }).click();
  await page.locator("#activity-rows .drag-handle").first().focus();
  await page.keyboard.press("ArrowDown");
  await page.getByRole("button", { name: "儲存網站設定" }).click();
  await expect(page.locator("#message")).toHaveText("設定已儲存。");
  expect(await activityTitles(page)).toEqual(["活動乙", "活動甲", "活動丙"]);
  await expect(page.getByRole("button", { name: "完成排序" })).toBeVisible();

  await page.locator('#activity-form input[name="title"]').fill("新活動");
  await page.locator('#activity-form input[name="sort_order"]').fill("9");
  await page.locator("#activity-form").evaluate((form) => form.requestSubmit());
  await expect(page.locator("#message")).toHaveText("請先完成或取消活動排序，再儲存活動。");
  expect(saves).toEqual(["settings"]);

  await page.getByRole("button", { name: "取消", exact: true }).click();
  expect(await activityTitles(page)).toEqual(["活動甲", "活動乙", "活動丙"]);
  await expect(newForm.locator('input[name="full_name"]')).toHaveValue("補登測試");
  await expect(newForm.locator('select[name="district_id"]')).toHaveValue("1");
  await expect(newForm.locator('input[name="activity_2"][value="true"]')).toBeChecked();
});

test("a saved reorder updates the page without reloading the reference data", async ({ page }) => {
  let referenceLoads = 0;
  await mockStaff(page, "admin", (payload) => { if (payload.action === "list_reference") referenceLoads += 1; }, "測試登記", {
    ...threeActivities,
    reorder_activities: () => ({ json: { success: true } }),
  });
  await login(page);
  await page.getByRole("button", { name: "調整排序" }).click();
  await page.locator("#activity-rows .drag-handle").first().focus();
  await page.keyboard.press("ArrowDown");
  await page.getByRole("button", { name: "完成排序" }).click();
  await expect(page.locator("#message")).toHaveText("活動排序已儲存。");
  expect(await activityTitles(page)).toEqual(["活動乙", "活動甲", "活動丙"]);
  await expect(page.locator("#new-registration-choices strong")).toHaveText(["活動乙", "活動甲", "活動丙"]);
  expect(referenceLoads).toBe(1);
});

test("a reorder rejected because the list changed reloads the activities and leaves reorder mode", async ({ page }) => {
  let rejected = false;
  const changed = structuredClone(threeActivities.list_reference().json);
  changed.activities.push({ id: 4, title: "活動丁", category: "other", is_published: true, sort_order: 4 });
  await mockStaff(page, "admin", () => {}, "測試登記", {
    list_reference: () => ({ json: rejected ? changed : threeActivities.list_reference().json }),
    reorder_activities: () => { rejected = true; return { status: 409, json: { error: "活動清單已有變動，請重新整理後再排序" } }; },
  });
  await login(page);
  await page.getByRole("button", { name: "調整排序" }).click();
  await page.locator("#activity-rows .drag-handle").first().focus();
  await page.keyboard.press("ArrowDown");
  await page.getByRole("button", { name: "完成排序" }).click();
  await expect(page.locator("#message")).toHaveText("活動清單已有變動，已重新載入，請再調整一次排序。");
  expect(await activityTitles(page)).toEqual(["活動甲", "活動乙", "活動丙", "活動丁"]);
  await expect(page.getByRole("button", { name: "調整排序" })).toBeVisible();
});

test("leaving reorder mode in the middle of a drag ends the drag", async ({ page }) => {
  await mockStaff(page, "admin", () => {}, "測試登記", threeActivities);
  await login(page);
  await page.getByRole("button", { name: "調整排序" }).click();
  await page.locator("#activity-rows").evaluate((element) => element.scrollIntoView({ block: "center" }));
  const from = await page.locator("#activity-rows .drag-handle").first().boundingBox();
  const last = await page.locator("#activity-rows tr").last().boundingBox();
  await page.mouse.move(from.x + from.width / 2, from.y + from.height / 2);
  await page.mouse.down();
  // Another finger taps 取消 while the first one is still dragging.
  await page.locator("#cancel-reorder").dispatchEvent("click");
  await page.mouse.move(from.x + from.width / 2, last.y + last.height - 2, { steps: 8 });
  await page.mouse.up();
  expect(await activityTitles(page)).toEqual(["活動甲", "活動乙", "活動丙"]);
  await expect(page.locator("#activity-rows tr.dragging")).toHaveCount(0);
});

test("the reorder buttons are fully on screen: in the table header on wide screens, beside the title on phones", async ({ page }) => {
  await mockStaff(page, "admin", () => {}, "測試登記", threeActivities);
  await login(page);
  const { width } = page.viewportSize();
  // toBeVisible ignores clipping by the table's scroll box, so check the button's box against the screen.
  const onScreen = async (name) => {
    const box = await page.getByRole("button", { name, exact: true }).boundingBox();
    expect(box.x, `${name} left edge`).toBeGreaterThanOrEqual(0);
    expect(box.x + box.width, `${name} right edge`).toBeLessThanOrEqual(width);
    return box;
  };
  await page.locator("#admin-activities").scrollIntoViewIfNeeded();
  const button = await onScreen("調整排序");
  const phoneLayout = await page.locator(".reorder-buttons").evaluate((element) => getComputedStyle(element).position === "absolute");
  if (!phoneLayout) {
    const row = await page.locator("#admin-activities thead tr").boundingBox();
    expect(row.x + row.width - (button.x + button.width)).toBeLessThan(24);
  }
  await page.getByRole("button", { name: "調整排序" }).click();
  await onScreen("完成排序");
  await onScreen("取消");
});

test("success messages float at the bottom and leave after 5 seconds; errors stay until closed", async ({ page }) => {
  await page.clock.install();
  await mockStaff(page, "admin", () => {}, "測試登記", threeActivities);
  await login(page);
  await page.getByRole("button", { name: "儲存網站設定" }).click();
  await expect(page.locator("#message")).toHaveText("設定已儲存。");
  await expect(page.getByRole("status")).toHaveText("設定已儲存。");
  const box = await page.locator("#toast").boundingBox();
  expect(box.y + box.height).toBeGreaterThan(page.viewportSize().height - 40);
  await page.clock.fastForward(6000);
  await expect(page.locator("#message")).toBeHidden();

  await page.getByRole("button", { name: "調整排序" }).click();
  await page.locator('#activity-form input[name="title"]').fill("新活動");
  await page.locator('#activity-form input[name="sort_order"]').fill("9");
  await page.locator("#activity-form").evaluate((form) => form.requestSubmit());
  await page.clock.fastForward(6000);
  await expect(page.locator("#message")).toHaveText("請先完成或取消活動排序，再儲存活動。");
  await page.getByRole("button", { name: "關閉訊息" }).click();
  await expect(page.locator("#message")).toBeHidden();
});

test("the note after a password change stays until the user acts on it", async ({ page }) => {
  await page.clock.install();
  await mockStaff(page, "staff", () => {}, "測試登記", {
    me: () => ({ json: { profile: { auth_user_id: "123e4567-e89b-42d3-a456-426614174000", display_name: "測試服事者", role: "staff", must_change_password: true } } }),
    change_password: () => ({ json: { success: true } }),
  });
  await login(page);
  const form = page.locator("#change-password-form");
  for (const input of await form.locator('input[type="password"]').all()) await input.fill("new-test-password-123");
  await form.locator('button[type="submit"]').click();
  await expect(page.locator("#message")).toHaveText("密碼已更改，請使用新密碼重新登入。");
  await page.clock.fastForward(10000);
  await expect(page.locator("#message")).toBeVisible();
});

const hostedRegistrations = {
  list_registrations: () => ({ json: { count: 4, registrations: [
    { id: "223e4567-e89b-42d3-a456-426614174001", serial_no: 4, full_name: "接待弟兄", district_id: 1, record_status: "active", import_status: "imported",
      registration_choices: [{ activity_id: 1, attending: true }], updated_at: "2026-11-05T00:00:00Z",
      registration_hosting: { status: "hosting", guest_type: "brother", guest_count: 2, pickup_count: 1 } },
    { id: "223e4567-e89b-42d3-a456-426614174002", serial_no: 3, full_name: "接待夫婦", district_id: 1, record_status: "active", import_status: "pending",
      registration_choices: [{ activity_id: 1, attending: true }], updated_at: "2026-11-05T00:00:00Z",
      registration_hosting: { status: "hosting", guest_type: "couple", guest_count: 4, pickup_count: 0 } },
    { id: "223e4567-e89b-42d3-a456-426614174003", serial_no: 2, full_name: "家人已登記", district_id: 1, record_status: "active", import_status: "pending",
      registration_choices: [{ activity_id: 1, attending: false }], updated_at: "2026-11-05T00:00:00Z",
      registration_hosting: { status: "family_registered", guest_type: null, guest_count: null, pickup_count: 2 } },
    { id: "223e4567-e89b-42d3-a456-426614174004", serial_no: 1, full_name: "未回覆接待", district_id: 1, record_status: "active", import_status: "pending",
      registration_choices: [{ activity_id: 1, attending: false }], updated_at: "2026-11-05T00:00:00Z", registration_hosting: null },
  ] } }),
};

test("staff edit a hosting answer, and an existing answer cannot be cleared", async ({ page }) => {
  let saved;
  await mockStaff(page, "staff", (payload) => { if (payload.action === "save_registration") saved = payload; }, "測試登記", hostedRegistrations);
  await login(page);
  await page.getByRole("row", { name: /接待弟兄/ }).getByRole("button", { name: "查看／處理" }).click();
  const hosting = page.locator("#detail-hosting");
  await expect(hosting.getByLabel("是", { exact: true })).toBeChecked();
  await expect(hosting.getByLabel("可以接待幾位？")).toHaveValue("2");
  await expect(hosting.getByLabel("接待對象")).toHaveValue("brother");
  await expect(hosting.getByLabel("2/19 或之前可以配搭接機幾位？")).toHaveValue("1");
  await hosting.getByLabel("可以接待幾位？").selectOption("4");
  await hosting.getByLabel("接待對象").selectOption({ label: "夫婦" });
  await hosting.getByLabel("2/19 或之前可以配搭接機幾位？").selectOption("5");
  await page.getByRole("button", { name: "儲存登記" }).click();
  await expect(page.locator("#message")).toHaveText("登記資料已儲存。");
  expect(saved.hosting).toEqual({ status: "hosting", guest_type: "couple", guest_count: 4, pickup_count: 5 });
  await expect(hosting.locator('input[name="hosting_status"]').first()).toHaveAttribute("required", "");

  // An unanswered registration may stay unanswered; pickup waits for an answer, so it cannot be lost.
  await page.getByRole("row", { name: /未回覆接待/ }).getByRole("button", { name: "查看／處理" }).click();
  await expect(hosting.locator('input[name="hosting_status"]').first()).not.toHaveAttribute("required", "");
  await expect(hosting.getByLabel("2/19 或之前可以配搭接機幾位？")).toBeDisabled();
  await page.getByRole("button", { name: "儲存登記" }).click();
  await expect.poll(() => saved.registration_id).toBe("223e4567-e89b-42d3-a456-426614174004");
  expect(saved.hosting).toBeNull();
});

test("a void registration shows its hosting answer with every control disabled", async ({ page }) => {
  const voided = { list_registrations: () => {
    const result = hostedRegistrations.list_registrations();
    result.json.registrations[0] = { ...result.json.registrations[0], record_status: "void" };
    return result;
  } };
  await mockStaff(page, "staff", () => {}, "測試登記", voided);
  await login(page);
  await page.getByRole("row", { name: /接待弟兄/ }).getByRole("button", { name: "查看／處理" }).click();
  const hosting = page.locator("#detail-hosting");
  await expect(hosting.getByLabel("可以接待幾位？")).toHaveValue("2");
  await expect(hosting.getByLabel("可以接待幾位？")).toBeDisabled();
  await expect(hosting.getByLabel("接待對象")).toBeDisabled();
  // An active registration opened next is editable again.
  await page.getByRole("row", { name: /接待夫婦/ }).getByRole("button", { name: "查看／處理" }).click();
  await expect(hosting.getByLabel("接待對象")).toBeEnabled();
});

test("補登 must answer hosting while the public survey is open", async ({ page }) => {
  let created;
  await mockStaff(page, "staff", () => {}, "測試登記", {
    list_reference: () => ({ json: {
      settings: { event_name: "測試", is_registration_open: true, is_hosting_open: true },
      districts: [{ id: 1, name: "林森", sort_order: 1 }],
      activities: [{ id: 1, title: "測試聚會", is_published: true, fee_amount: 0 }], program: [],
    } }),
    create_registration: (payload) => { created = payload; return { status: 201, json: { serial_no: 2 } }; },
  });
  await login(page);
  const form = page.locator("#new-registration-form");
  await form.locator('input[name="full_name"]').fill("補登接待");
  await form.locator('select[name="district_id"]').selectOption("1");
  await form.locator('input[name="activity_1"][value="false"]').check();
  await form.getByRole("button", { name: "建立補登" }).click();
  expect(created).toBeUndefined();
  const hosting = page.locator("#new-registration-hosting");
  await hosting.getByLabel("是", { exact: true }).check();
  await hosting.getByLabel("接待對象").selectOption({ label: "姊妹" });
  await hosting.getByLabel("可以接待幾位？").selectOption("2");
  await form.getByRole("button", { name: "建立補登" }).click();
  await expect(page.locator("#new-registration-code")).toHaveText("已建立流水號 2。本人日後可用相同的姓名與區查詢。");
  expect(created.hosting).toEqual({ status: "hosting", guest_type: "sister", guest_count: 2, pickup_count: 0 });
  await expect(hosting.locator('input[name="hosting_status"]:checked')).toHaveCount(0);
});

test("statistics count hosting answers and capacity", async ({ page }) => {
  await mockStaff(page, "staff", () => {}, "測試登記", hostedRegistrations);
  await login(page);
  await page.getByRole("button", { name: "更新統計" }).click();
  const answers = page.locator("#hosting-status-stats-rows tr");
  await expect(answers).toHaveCount(4);
  await expect(answers.nth(0).locator("td")).toHaveText(["是", "2"]);
  await expect(answers.nth(1).locator("td")).toHaveText(["否", "0"]);
  await expect(answers.nth(2).locator("td")).toHaveText(["家人已登記開家接待", "1"]);
  await expect(answers.nth(3).locator("td")).toHaveText(["未回覆", "1"]);
  const capacity = page.locator("#hosting-capacity-stats-rows tr");
  await expect(capacity).toHaveCount(5);
  await expect(capacity.nth(0).locator("td")).toHaveText(["夫婦", "1", "4"]);
  await expect(capacity.nth(1).locator("td")).toHaveText(["弟兄", "1", "2"]);
  await expect(capacity.nth(2).locator("td")).toHaveText(["姊妹", "0", "0"]);
  await expect(capacity.nth(3).locator("td")).toHaveText(["不拘", "0", "0"]);
  await expect(capacity.nth(4).locator("td")).toHaveText(["合計", "2", "6"]);
  // Pickup counts every answer with seats, here 是 (1) and 家人已登記開家接待 (2).
  await expect(page.locator("#hosting-pickup-stats-rows tr td")).toHaveText(["可配搭接機", "2", "3"]);
});

test("CSV adds the hosting columns", async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== "desktop-chromium");
  await mockStaff(page, "staff", () => {}, "測試登記", hostedRegistrations);
  await login(page);
  const download = page.waitForEvent("download");
  await page.getByRole("button", { name: "下載 CSV" }).click();
  const lines = (await readFile(await (await download).path(), "utf8")).split("\r\n");
  expect(lines[0]).toMatch(/"開家接待","接待對象","可接待人數","可接機人數"$/);
  expect(lines[1]).toMatch(/"是","弟兄","2","1"$/);
  expect(lines[2]).toMatch(/"是","夫婦","4","0"$/);
  expect(lines[3]).toMatch(/"家人已登記開家接待","","","2"$/);
  expect(lines[4]).toMatch(/"未回覆","","",""$/);
});

test("admins save the hosting switch and description from their own card", async ({ page }) => {
  let saved;
  await mockStaff(page, "admin", (payload) => { if (payload.action === "save_reference") saved = payload; });
  page.on("dialog", (dialog) => dialog.accept());
  await login(page);
  const form = page.locator("#hosting-settings-form");
  await form.getByLabel("開放開家接待調查").check();
  await form.locator('textarea[name="hosting_description"]').fill("接待期間 2/19～2/22");
  await form.getByRole("button", { name: "儲存開家接待設定" }).click();
  await expect(page.locator("#message")).toHaveText("設定已儲存。");
  expect(saved).toEqual({ action: "save_reference", kind: "hosting", data: { is_hosting_open: true, hosting_description: "接待期間 2/19～2/22" } });
});

test("admins save the site note from the right side of the settings card", async ({ page }) => {
  let saved;
  await mockStaff(page, "admin", (payload) => { if (payload.action === "save_reference") saved = payload; });
  await login(page);
  const form = page.locator("#settings-form");
  const note = form.locator('textarea[name="event_note"]');
  await expect(note).toHaveAttribute("maxlength", "500");
  await note.fill("捷運國父紀念館站 5 號出口 https://maps.app.goo.gl/abc123");
  await form.getByRole("button", { name: "儲存網站設定" }).click();
  await expect(page.locator("#message")).toHaveText("設定已儲存。");
  expect(saved.data.event_note).toBe("捷運國父紀念館站 5 號出口 https://maps.app.goo.gl/abc123");

  const { width } = page.viewportSize();
  const [left, right] = await form.evaluate((element) =>
    [".registration-main", ".registration-columns > label"].map((selector) => {
      const { x, y, width: w, height } = element.querySelector(selector).getBoundingClientRect();
      return { x, y, width: w, height };
    }));
  if (width >= 896) {
    expect(right.x).toBeGreaterThan(left.x + left.width - 1);
    expect(Math.abs(right.y - left.y)).toBeLessThan(2);
  } else {
    expect(right.y).toBeGreaterThan(left.y + left.height - 1);
  }
  expect(right.x + right.width).toBeLessThanOrEqual(width);
});

test("staff do not see the hosting settings card", async ({ page }) => {
  await mockStaff(page, "staff");
  await login(page);
  await expect(page.getByText("測試登記")).toBeVisible();
  await expect(page.locator("#admin-hosting")).toBeHidden();
});

test("hosting sits right of the activity choices on wide screens and below them on phones", async ({ page }) => {
  await mockStaff(page, "staff", () => {}, "測試登記", hostedRegistrations);
  await login(page);
  await page.getByRole("row", { name: /接待弟兄/ }).getByRole("button", { name: "查看／處理" }).click();
  const { width } = page.viewportSize();
  // Both boxes in one call: opening the record scrolls smoothly, so separate reads would disagree.
  const [left, right] = await page.locator("#edit-registration-form").evaluate((form) =>
    [".registration-main", ".hosting-panel"].map((selector) => {
      const { x, y, width: w, height } = form.querySelector(selector).getBoundingClientRect();
      return { x, y, width: w, height };
    }));
  if (width >= 896) {
    expect(right.x).toBeGreaterThan(left.x + left.width - 1);
    expect(Math.abs(right.y - left.y)).toBeLessThan(2);
  } else {
    expect(right.y).toBeGreaterThan(left.y + left.height - 1);
  }
  expect(right.x + right.width).toBeLessThanOrEqual(width);
});

test("補登 may leave hosting unanswered while the survey is closed, until the server says it opened", async ({ page }) => {
  const created = [];
  await mockStaff(page, "staff", () => {}, "測試登記", {
    create_registration: (payload) => {
      created.push(payload);
      return created.length === 1
        ? { status: 409, json: { error: "開家接待調查已開放，請回答開家接待後再建立補登；看不到接待欄位時請重新整理頁面", code: "HOSTING_REQUIRED" } }
        : { status: 201, json: { serial_no: 2 } };
    },
  });
  await login(page);
  const form = page.locator("#new-registration-form");
  await form.locator('input[name="full_name"]').fill("補登未答");
  await form.locator('select[name="district_id"]').selectOption("1");
  await form.locator('input[name="activity_1"][value="false"]').check();
  await form.getByRole("button", { name: "建立補登" }).click();
  await expect(page.locator("#message")).toHaveText("開家接待調查已開放，請回答開家接待後再建立補登；看不到接待欄位時請重新整理頁面");
  expect(created[0].hosting).toBeNull();
  const hosting = page.locator("#new-registration-hosting");
  await expect(hosting.locator('input[name="hosting_status"]').first()).toHaveAttribute("required", "");
  await expect(form.locator('input[name="full_name"]')).toHaveValue("補登未答");
  await hosting.getByLabel("否", { exact: true }).check();
  await form.getByRole("button", { name: "建立補登" }).click();
  await expect(page.locator("#new-registration-code")).toHaveText("已建立流水號 2。本人日後可用相同的姓名與區查詢。");
  expect(created[1].hosting).toEqual({ status: "not_hosting", guest_type: null, guest_count: null, pickup_count: 0 });
});

test("a password set for another admin must be changed at their next login", async ({ page }) => {
  await mockStaff(page, "admin", () => {}, "測試登記", {
    list_staff: () => ({ json: { staff: [
      { auth_user_id: self, username: "tester", display_name: "測試服事者", role: "admin", is_active: true },
      { auth_user_id: other, username: "backup", display_name: "備援管理員", role: "admin", is_active: true },
    ] } }),
    set_staff_password: () => ({ json: { success: true, must_change_password: true } }),
  });
  page.on("dialog", (dialog) => dialog.accept());
  await login(page);
  await page.locator("#staff-rows tr").nth(1).getByRole("button", { name: "修改" }).click();
  const form = page.locator("#staff-password-form");
  await form.locator('input[name="password"]').fill("new-admin-password-1");
  await form.getByRole("button", { name: "設定密碼" }).click();
  await expect(page.locator("#message")).toHaveText("密碼已設定。對方是管理員，下次登入時須改成自己的密碼；請以安全方式私下交付。");
});
