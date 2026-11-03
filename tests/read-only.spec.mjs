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

test("closed registration remains queryable and disables edits", async ({ page }) => {
  const actions = [];
  await page.route("**/functions/v1/registration", async (route) => {
    const request = route.request();
    if (request.method() === "GET") {
      return route.fulfill({ json: {
        settings: { event_name: "測試活動", venue: "", address: "", is_registration_open: false, registration_deadline_at: null },
        districts: [{ id: 1, name: "測試區" }],
        activities: [{ id: 1, title: "測試活動", description: null }],
        program: [
          { event_date: "2027-02-20", start_time: "12:30:00", end_time: "14:00:00", title: "第一堂聚會", note: null },
          { event_date: "2027-02-21", start_time: "09:00:00", end_time: null, title: "第四堂聚會", note: null },
        ],
      } });
    }
    actions.push(request.postDataJSON().action);
    return route.fulfill({ json: {
      full_name: "測試登記", district_id: 1,
      record_status: "active", can_change: false,
      choices: [{ activity_id: 1, attending: true }],
    } });
  });

  await page.goto("/");
  await expect(page.locator(".program-day")).toHaveCount(2);
  await expect(page.locator(".program-day").first()).toContainText(/2月20日\s*星期六/);
  await expect(page.locator(".program-day").first()).toContainText("12:30–14:00");
  await expect(page.locator(".program-day").last()).toContainText(/2月21日\s*星期日/);
  await expect(page.locator('#registration-form button[type="submit"]')).toBeDisabled();
  await page.getByRole("tab", { name: "查詢或修改登記" }).click();
  await page.locator('#query-form input[name="query_code"]').fill("zzzzzzzz");
  await page.locator('#query-form button[type="submit"]').click();

  await expect(page.locator("#edit-form")).toBeVisible();
  await expect(page.getByText("38-0001")).toHaveCount(0);
  await expect(page.locator('#edit-form input[name="full_name"]')).toHaveValue("測試登記");
  await expect(page.getByRole("button", { name: "儲存", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: /取消登記|恢復登記/ })).toHaveCount(0);
  await expect(page.locator("#edit-form button")).toHaveCount(1);
  await expectEqualIdentityColumns(page.locator("#edit-form .identity-fields"));
  for (const control of await page.locator("#edit-form input, #edit-form select, #edit-form button").all()) {
    await expect(control).toBeDisabled();
  }
  expect(actions).toEqual(["query"]);

  for (const width of [360, 768, 1366, 1920]) {
    await page.setViewportSize({ width, height: 900 });
    expect(await page.evaluate(() => document.documentElement.scrollWidth), `${width}px horizontal overflow`).toBeLessThanOrEqual(width);
    await expect(page.locator("#program-section")).toBeVisible();
    await expect(page.locator("#query-form")).toBeVisible();
  }
});

test("save skips unchanged data and resets the comparison baseline", async ({ page }) => {
  const requests = [];
  await page.route("**/functions/v1/registration", async (route) => {
    const request = route.request();
    if (request.method() === "GET") {
      return route.fulfill({ json: {
        settings: { event_name: "測試活動", venue: "", address: "", is_registration_open: true },
        districts: [{ id: 1, name: "測試區" }],
        activities: [{ id: 1, title: "測試活動", description: null }],
        program: [],
      } });
    }
    const body = request.postDataJSON();
    requests.push(body);
    if (body.action === "query") {
      return route.fulfill({ json: {
        full_name: "測試登記", district_id: 1,
        record_status: "active", can_change: true,
        choices: [{ activity_id: 1, attending: true }],
      } });
    }
    return route.fulfill({ json: { ok: true } });
  });

  await page.goto("/");
  await page.getByRole("tab", { name: "查詢或修改登記" }).click();
  await page.locator('#query-form input[name="query_code"]').fill("zzzzzzzz");
  await page.getByRole("button", { name: "查詢" }).click();

  const name = page.locator('#edit-form input[name="full_name"]');
  const attending = page.locator('#edit-form input[name="activity_1"][value="true"]');
  await name.fill("暫時修改");
  await name.fill("  測試登記  ");
  await page.locator('#edit-form input[name="activity_1"][value="false"]').check();
  await attending.check();
  await page.getByRole("button", { name: "儲存", exact: true }).click();
  await expect(page.locator("#page-message")).toHaveText("目前內容沒有變更。");
  expect(requests.map(({ action }) => action)).toEqual(["query"]);

  await name.fill("  測試登記修改  ");
  await page.getByRole("button", { name: "儲存", exact: true }).click();
  await expect(page.locator("#page-message")).toHaveText("登記資料已儲存。");
  expect(requests.map(({ action }) => action)).toEqual(["query", "update"]);
  expect(requests[1].full_name).toBe("測試登記修改");

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
    if (request.method() === "GET") {
      return route.fulfill({ json: {
        settings: { event_name: "測試活動", venue: "", address: "", is_registration_open: true },
        districts: [{ id: 1, name: "測試區" }],
        activities: [{ id: 1, title: "測試活動", description: null }],
        program: [],
      } });
    }
    const body = request.postDataJSON();
    requests.push(body);
    if (body.action === "query") {
      queryCount += 1;
      if (queryCount === 2) await new Promise((resolve) => { releasePendingQuery = resolve; });
      return route.fulfill({ json: {
        full_name: "測試登記", district_id: 1,
        record_status: "active", can_change: true,
        choices: [{ activity_id: 1, attending: true }],
      } });
    }
    return route.fulfill({ json: { ok: true } });
  });

  await page.goto("/");
  await page.getByRole("tab", { name: "查詢或修改登記" }).click();
  const queryCode = page.locator('#query-form input[name="query_code"]');
  await queryCode.fill("zzzzzzzz");
  await page.getByRole("button", { name: "查詢" }).click();
  await expect(page.locator("#edit-form")).toBeVisible();

  await queryCode.fill("yyyyyyyy");
  await page.getByRole("button", { name: "查詢" }).click();
  await expect(page.locator("#edit-form")).toBeHidden();
  await page.locator("#edit-form").dispatchEvent("submit");
  await expect(page.locator("#page-message")).toHaveText("請先查詢登記資料。");
  expect(requests.map(({ action }) => action)).toEqual(["query", "query"]);

  releasePendingQuery();
  await expect(page.locator("#edit-form")).toBeVisible();
});

test("registration tabs and success page show only the query code", async ({ page }) => {
  let submittedChoices;
  await page.route("**/functions/v1/registration", async (route) => {
    if (route.request().method() === "GET") {
      return route.fulfill({ json: {
        settings: { event_name: "測試活動", venue: "", address: "", is_registration_open: true },
        districts: [{ id: 1, name: "測試區" }],
        activities: [
          { id: 1, title: "測試活動", description: null },
          { id: 2, title: "週六午餐", venue: "京星港式飲茶 PART1", address: "台北市敦化南路一段 216 號 2 樓", fee_amount: 250, description: "用餐時間待確認" },
        ],
        program: [],
      } });
    }
    submittedChoices = route.request().postDataJSON().choices;
    return route.fulfill({ status: 201, json: { query_code: "a2b3c4d5" } });
  });

  await page.goto("/");
  await expect(page.getByRole("tab", { name: "登記參加" })).toHaveAttribute("aria-selected", "true");
  await expectEqualIdentityColumns(page.locator("#registration-form .identity-fields"));
  await expect(page.locator("#query-form")).toBeHidden();
  await page.getByRole("tab", { name: "查詢或修改登記" }).click();
  await expect(page.locator("#query-form")).toBeVisible();
  await expect(page.getByLabel(/請輸入查詢碼/)).toHaveAttribute("minlength", "8");
  await page.getByRole("tab", { name: "登記參加" }).click();
  await expect(page.locator("#activities")).toContainText("京星港式飲茶 PART1");
  await expect(page.locator("#activities")).toContainText("規劃費用：NT$250／人");
  await page.locator('#registration-form input[name="full_name"]').fill("測試登記");
  await page.locator('#registration-form select[name="district_id"]').selectOption("1");
  await page.locator('#registration-form input[name="activity_1"][value="false"]').check();
  await page.locator('#registration-form input[name="activity_2"][value="false"]').check();
  await page.getByRole("button", { name: "送出登記" }).click();

  await expect(page).toHaveURL(/success\.html$/);
  await expect(page.locator("#query-code")).toHaveText("a2b3c4d5");
  expect(submittedChoices).toEqual([
    { activity_id: 1, attending: false },
    { activity_id: 2, attending: false },
  ]);
  await expect(page.getByText("流水號")).toHaveCount(0);
  await expect(page.getByRole("button", { name: "複製查詢碼" })).toBeVisible();
  await expect(page.getByRole("button", { name: /列印|儲存/ })).toHaveCount(0);
  await page.locator("#saved-confirmation").check();
});
