import { expect, test } from "@playwright/test";

async function expectEqualIdentityColumns(fields) {
  const boxes = await fields.locator(":scope > label").evaluateAll((labels) => labels.map((label) => {
    const { x, y, width } = label.getBoundingClientRect();
    return { x, y, width };
  }));
  expect(boxes).toHaveLength(2);
  expect(Math.abs(boxes[0].y - boxes[1].y)).toBeLessThan(1);
  expect(Math.abs(boxes[0].width - boxes[1].width)).toBeLessThan(1);
  expect(boxes[1].x).toBeGreaterThan(boxes[0].x);
}

const openPage = (open = true) => ({
  settings: { event_name: "測試活動", venue: "", address: "", is_registration_open: open, registration_deadline_at: null },
  districts: [{ id: 1, name: "測試區" }, { id: 2, name: "第二區" }],
  activities: [{ id: 1, title: "測試活動", description: null }],
  program: [],
});

const queried = (canChange) => ({
  full_name: "測試登記", district_id: 1, can_change: canChange,
  choices: [{ activity_id: 1, title: "測試活動", attending: true }],
});

async function query(page, name = "測試登記", district = "1") {
  await page.getByRole("tab", { name: "查詢或修改登記" }).click();
  await page.locator('#query-form input[name="full_name"]').fill(name);
  await page.locator('#query-form select[name="district_id"]').selectOption(district);
  await page.getByRole("button", { name: "查詢" }).click();
}

test("closed registration remains queryable by name and district and disables edits", async ({ page }) => {
  const bodies = [];
  await page.route("**/functions/v1/registration", async (route) => {
    const request = route.request();
    if (request.method() === "GET") {
      return route.fulfill({ json: { ...openPage(false), program: [
        { event_date: "2027-02-20", start_time: "12:30:00", end_time: "14:00:00", title: "第一堂聚會", note: null },
        { event_date: "2027-02-21", start_time: "09:00:00", end_time: null, title: "第四堂聚會", note: null },
      ] } });
    }
    bodies.push(request.postDataJSON());
    return route.fulfill({ json: queried(false) });
  });

  await page.goto("/");
  await expect(page.locator(".program-day")).toHaveCount(2);
  await expect(page.locator(".program-day").first()).toContainText(/2月20日\s*星期六/);
  await expect(page.locator(".program-day").first()).toContainText("12:30–14:00");
  await expect(page.locator('#registration-form button[type="submit"]')).toBeDisabled();
  await query(page, "  測試登記  ");

  await expect(page.locator("#edit-form")).toBeVisible();
  await expect(page.locator("#edit-identity")).toHaveText("測試登記｜測試區");
  await expect(page.locator('#edit-form input[name="full_name"]')).toHaveCount(0);
  await expect(page.locator("#edit-form select")).toHaveCount(0);
  await expect(page.locator("#edit-form button")).toHaveCount(1);
  for (const control of await page.locator("#edit-form input, #edit-form button").all()) {
    await expect(control).toBeDisabled();
  }
  expect(bodies).toEqual([{ action: "query", full_name: "測試登記", district_id: 1 }]);
  await expectEqualIdentityColumns(page.locator("#query-form .identity-fields"));

  for (const width of [360, 768, 1366, 1920]) {
    await page.setViewportSize({ width, height: 900 });
    expect(await page.evaluate(() => document.documentElement.scrollWidth), `${width}px horizontal overflow`).toBeLessThanOrEqual(width);
    await expect(page.locator("#program-section")).toBeVisible();
    await expect(page.locator("#query-form")).toBeVisible();
  }
});

test("a query that finds nothing shows the server message", async ({ page }) => {
  await page.route("**/functions/v1/registration", async (route) => {
    if (route.request().method() === "GET") return route.fulfill({ json: openPage() });
    return route.fulfill({ status: 404, json: { error: "查無登記資料，請確認姓名寫法與區和登記時相同" } });
  });
  await page.goto("/");
  await query(page, "不存在");
  await expect(page.locator("#page-message")).toHaveText("查無登記資料，請確認姓名寫法與區和登記時相同");
  await expect(page.locator("#edit-form")).toBeHidden();
});

test("save sends only choices with the queried name and district, and skips unchanged choices", async ({ page }) => {
  const requests = [];
  await page.route("**/functions/v1/registration", async (route) => {
    const request = route.request();
    if (request.method() === "GET") return route.fulfill({ json: openPage() });
    const body = request.postDataJSON();
    requests.push(body);
    if (body.action === "query") return route.fulfill({ json: queried(true) });
    return route.fulfill({ json: { success: true } });
  });

  await page.goto("/");
  await query(page);
  const attending = page.locator('#edit-form input[name="activity_1"][value="true"]');
  const notAttending = page.locator('#edit-form input[name="activity_1"][value="false"]');
  await notAttending.check();
  await attending.check();
  await page.getByRole("button", { name: "儲存", exact: true }).click();
  await expect(page.locator("#page-message")).toHaveText("目前內容沒有變更。");
  expect(requests.map(({ action }) => action)).toEqual(["query"]);

  await notAttending.check();
  await page.getByRole("button", { name: "儲存", exact: true }).click();
  await expect(page.locator("#page-message")).toHaveText("登記資料已儲存。");
  expect(requests[1]).toEqual({
    action: "update", full_name: "測試登記", district_id: 1, choices: [{ activity_id: 1, attending: false }],
  });

  await page.getByRole("button", { name: "儲存", exact: true }).click();
  await expect(page.locator("#page-message")).toHaveText("目前內容沒有變更。");
  expect(requests.map(({ action }) => action)).toEqual(["query", "update"]);
});

test("starting a new query prevents the previous form from being saved", async ({ page }) => {
  const requests = [];
  let releasePendingQuery;
  let queryCount = 0;
  await page.route("**/functions/v1/registration", async (route) => {
    const request = route.request();
    if (request.method() === "GET") return route.fulfill({ json: openPage() });
    const body = request.postDataJSON();
    requests.push(body);
    if (body.action === "query") {
      queryCount += 1;
      if (queryCount === 2) await new Promise((resolve) => { releasePendingQuery = resolve; });
      return route.fulfill({ json: queried(true) });
    }
    return route.fulfill({ json: { success: true } });
  });

  await page.goto("/");
  await query(page);
  await expect(page.locator("#edit-form")).toBeVisible();

  await page.locator('#query-form input[name="full_name"]').fill("另一個人");
  await page.getByRole("button", { name: "查詢" }).click();
  await expect(page.locator("#edit-form")).toBeHidden();
  await page.locator("#edit-form").dispatchEvent("submit");
  await expect(page.locator("#page-message")).toHaveText("請先查詢登記資料。");
  expect(requests.map(({ action }) => action)).toEqual(["query", "query"]);

  releasePendingQuery();
  await expect(page.locator("#edit-form")).toBeVisible();
});

test("a name and district already registered is refused with the server message", async ({ page }) => {
  await page.route("**/functions/v1/registration", async (route) => {
    if (route.request().method() === "GET") return route.fulfill({ json: openPage() });
    return route.fulfill({ status: 409, json: { error: "此姓名與區已經登記過，如需查看或修改，請使用「查詢或修改登記」" } });
  });
  await page.goto("/");
  await page.locator('#registration-form input[name="full_name"]').fill("測試登記");
  await page.locator('#registration-form select[name="district_id"]').selectOption("1");
  await page.locator('#registration-form input[name="activity_1"][value="true"]').check();
  await page.getByRole("button", { name: "送出登記" }).click();
  await expect(page.locator("#page-message")).toHaveText("此姓名與區已經登記過，如需查看或修改，請使用「查詢或修改登記」");
  await expect(page).not.toHaveURL(/success\.html$/);
});

test("registration tabs and success page show what was submitted", async ({ page }) => {
  let submitted;
  await page.route("**/functions/v1/registration", async (route) => {
    if (route.request().method() === "GET") {
      return route.fulfill({ json: { ...openPage(), activities: [
        { id: 1, title: "測試活動", description: null },
        { id: 2, title: "週六午餐", venue: "測試餐廳", address: "測試地址", fee_amount: 250, description: "用餐時間待確認" },
      ] } });
    }
    submitted = route.request().postDataJSON();
    return route.fulfill({ status: 201, json: { success: true } });
  });

  await page.goto("/");
  await expect(page.getByRole("tab", { name: "登記參加" })).toHaveAttribute("aria-selected", "true");
  await expectEqualIdentityColumns(page.locator("#registration-form .identity-fields"));
  await expect(page.locator("#query-form")).toBeHidden();
  await page.getByRole("tab", { name: "查詢或修改登記" }).click();
  await expect(page.locator("#query-form")).toBeVisible();
  await expect(page.locator('#query-form select[name="district_id"] option')).toHaveCount(3);
  await page.getByRole("tab", { name: "登記參加" }).click();
  await expect(page.locator("#activities")).toContainText("規劃費用：NT$250／人");
  await page.locator('#registration-form input[name="full_name"]').fill(" David Wang ");
  await page.locator('#registration-form select[name="district_id"]').selectOption("2");
  await page.locator('#registration-form input[name="activity_1"][value="true"]').check();
  await page.locator('#registration-form input[name="activity_2"][value="false"]').check();
  await page.getByRole("button", { name: "送出登記" }).click();

  await expect(page).toHaveURL(/success\.html$/);
  expect(submitted.choices).toEqual([
    { activity_id: 1, attending: true },
    { activity_id: 2, attending: false },
  ]);
  await expect(page.locator("#summary-identity")).toHaveText("David Wang｜第二區");
  await expect(page.locator("#summary-choices li")).toHaveText(["測試活動：參加", "週六午餐：不參加"]);
  await expect(page.getByText("查詢碼")).toHaveCount(0);
  await expect(page.getByRole("link", { name: "回登記頁" })).toBeEnabled();
  // A reload (for example mobile Safari restoring the tab) keeps the summary.
  await page.reload();
  await expect(page.locator("#summary-identity")).toHaveText("David Wang｜第二區");
  // Going back to the form clears it, so the next person on a shared device cannot reopen it.
  await page.getByRole("link", { name: "回登記頁" }).click();
  await expect(page.getByRole("button", { name: "送出登記" })).toBeVisible();
  await page.goto("/success.html");
  await expect(page).not.toHaveURL(/success\.html$/);
});
