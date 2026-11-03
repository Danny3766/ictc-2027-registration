import { expect, test } from "@playwright/test";

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
      serial_no: "38-0001", full_name: "測試登記", district_id: 1,
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
  await page.locator('#query-form input[name="query_code"]').fill("zzzzz");
  await page.locator('#query-form button[type="submit"]').click();

  await expect(page.locator("#edit-form")).toBeVisible();
  await expect(page.locator("#serial-no")).toHaveText("38-0001");
  await expect(page.locator('#edit-form input[name="full_name"]')).toHaveValue("測試登記");
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
