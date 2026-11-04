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
        : { status: 201, json: { serial_no: 2 } };
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
  await expect(page.locator("#new-registration-code")).toHaveText("已建立流水號 2。本人日後可用相同的姓名與區查詢。");
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
