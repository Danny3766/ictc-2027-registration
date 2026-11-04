const config = window.APP_CONFIG;
const loginPanel = document.querySelector("#login-panel");
const changePasswordPanel = document.querySelector("#change-password-panel");
const staffPanel = document.querySelector("#staff-panel");
const message = document.querySelector("#message");
const sessionKey = "ictc_staff_session";
let session;
try { session = JSON.parse(sessionStorage.getItem(sessionKey) || "null"); }
catch { sessionStorage.removeItem(sessionKey); session = null; }
let profile;
let reference;
let page = 0;
let count = 0;
let search = "";
let visibleRegistrations = [];
let selectedRegistration;
const adminSections = ["#admin-accounts", "#admin-settings", "#admin-districts", "#admin-activities", "#admin-program"];

function showAdminSections(visible) {
  for (const selector of adminSections) document.querySelector(selector).hidden = !visible;
  for (const link of document.querySelectorAll("[data-admin-link]")) link.hidden = !visible;
}

// Labels for stored codes, so the page never shows values like "reimport_needed" or "admin".
const labels = {
  record: { active: "有效", void: "作廢", cancelled: "已取消" },
  import: { pending: "待匯入", imported: "已匯入", reimport_needed: "需重新匯入" },
  role: { admin: "管理員", staff: "服事者" },
  category: { meeting: "聚會", meal: "用餐", other: "其他" },
};
const label = (group, value) => labels[group][value] ?? value;

// Short Taiwan time, for example "11/4 08:30".
function shortTime(value) {
  return new Date(value).toLocaleString("zh-TW", {
    timeZone: "Asia/Taipei", month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false,
  });
}

// Reference tables show codes and timestamps the way the forms describe them.
function displayValue(column, value) {
  if (typeof value === "boolean") return value ? "是" : "否";
  if (value == null || value === "") return "";
  if (column === "category") return label("category", value);
  if (column === "starts_at") return shortTime(value);
  if (column === "start_time") return value.slice(0, 5);
  return value;
}

function statusCell(row, group, value) {
  const badge = document.createElement("span");
  badge.className = `status status-${value}`;
  badge.textContent = label(group, value);
  cell(row, "").append(badge);
}

if (config?.environment === "test") document.querySelector("#test-banner").hidden = false;

function showMessage(value, error = false) {
  message.textContent = value;
  message.classList.toggle("error", error);
  message.hidden = false;
}

function clearSession() {
  session = null;
  sessionStorage.removeItem(sessionKey);
  profile = null;
  loginPanel.hidden = false;
  changePasswordPanel.hidden = true;
  staffPanel.hidden = true;
  showAdminSections(false);
  document.querySelector("#identity").textContent = "";
  document.querySelector("#temporary-password").textContent = "";
  document.querySelector("#temporary-password").hidden = true;
  document.querySelector("#new-registration-code").textContent = "";
  document.querySelector("#new-registration-code").hidden = true;
  setReordering(false);
  // The 補登 form keeps input across redraws, so a shared device must not hand it to the next login.
  document.querySelector("#new-registration-form").reset();
  for (const selector of ["#registration-rows", "#staff-rows"]) {
    document.querySelector(selector).replaceChildren();
  }
  document.querySelector("#stats-rows").replaceChildren();
  document.querySelector("#district-stats-rows").replaceChildren();
  document.querySelector("#district-activity-stats-rows").replaceChildren();
  document.querySelector("#stats-summary").textContent = "";
  document.querySelector("#registration-detail").hidden = true;
  selectedRegistration = null;
  visibleRegistrations = [];
}

async function authRequest(path, body) {
  const response = await fetch(`${config.supabaseUrl}/auth/v1/${path}`, {
    method: "POST",
    headers: { apikey: config.publishableKey, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = new Error(response.status < 500 ? "登入失敗，請確認帳號與密碼" : "登入服務暫時無法使用，請稍後再試");
    error.status = response.status;
    throw error;
  }
  session ={ access_token: result.access_token, refresh_token: result.refresh_token, expires_at: Date.now() + result.expires_in * 1000 };
  sessionStorage.setItem(sessionKey, JSON.stringify(session));
}

async function accessToken() {
  if (!session) throw new Error("請先登入");
  if (Date.now() >= session.expires_at - 60_000) {
    try {
      await authRequest("token?grant_type=refresh_token", { refresh_token: session.refresh_token });
    } catch (error) {
      // Only a rejected refresh token ends the login; a network error or Auth 5xx keeps it for a retry.
      if (![400, 401, 403].includes(error.status)) throw new Error("暫時無法連線，請稍後再試");
      clearSession();
      throw new Error("登入已過期，請重新登入");
    }
  }
  return session.access_token;
}

async function api(action, values = {}) {
  if (!config?.supabaseUrl || !config?.publishableKey) throw new Error("網站尚未設定 Supabase 公開連線資訊");
  const response = await fetch(`${config.supabaseUrl}/functions/v1/staff`, {
    method: "POST",
    headers: { apikey: config.publishableKey, Authorization: `Bearer ${await accessToken()}`, "Content-Type": "application/json" },
    body: JSON.stringify({ action, ...values }),
  });
  const result = await response.json().catch(() => ({}));
  if (response.status === 401) clearSession();
  if (!response.ok) {
    const error = new Error(result.error || "後台暫時無法使用");
    error.status = response.status;
    throw error;
  }
  return result;
}

function cell(row, value) {
  const item = document.createElement("td");
  item.textContent = String(value ?? "");
  row.append(item);
  return item;
}

function taipeiInput(value) {
  return value ? new Date(new Date(value).getTime() + 8 * 60 * 60 * 1000).toISOString().slice(0, 16) : "";
}

function taipeiTimestamp(value) {
  return value ? `${value}:00+08:00` : null;
}

function editButton(row, callback) {
  const action = cell(row, "");
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = "編輯";
  button.addEventListener("click", callback);
  action.append(button);
}

function fillForm(form, values, scroll = true) {
  for (const [name, value] of Object.entries(values)) {
    const field = form.elements.namedItem(name);
    if (!field) continue;
    if (field.type === "checkbox") field.checked = Boolean(value);
    else field.value = value ?? "";
  }
  if (scroll) form.scrollIntoView({ behavior: "smooth", block: "center" });
}

// The edited row's id lives only here, so abandoning an edit (取消編輯) can never update that row.
function setEditing(form, item) {
  const submit = form.querySelector('button[type="submit"]');
  submit.dataset.label ??= submit.textContent;
  if (item) {
    form.dataset.editingId = item.id;
    submit.textContent = `${submit.dataset.label}（編輯：${item.title ?? item.name}）`;
  } else {
    delete form.dataset.editingId;
    submit.textContent = submit.dataset.label;
  }
}

// `only` redraws one table, so redrawing activities keeps unsaved input in the other forms.
// A full redraw leaves the activity table alone while reordering, so the unsaved drag order stays.
function renderReferenceRows(only) {
  for (const [table, items, columns, form, transform] of [
    ["#district-rows", reference.districts, ["name", "sort_order"], "#district-form", (item) => item],
    ["#activity-rows", reference.activities, ["title", "category", "starts_at", "is_published"], "#activity-form",
      (item) => ({ ...item, starts_at: taipeiInput(item.starts_at), ends_at: taipeiInput(item.ends_at) })],
    ["#program-rows", reference.program, ["event_date", "start_time", "title", "is_visible"], "#program-form",
      (item) => ({ ...item, start_time: item.start_time?.slice(0, 5), end_time: item.end_time?.slice(0, 5) })],
  ]) {
    if (only ? table !== only : table === "#activity-rows" && activitySection.classList.contains("reordering")) continue;
    const rows = document.querySelector(table);
    rows.replaceChildren();
    for (const item of items) {
      const row = document.createElement("tr");
      for (const column of columns) cell(row, displayValue(column, item[column]));
      editButton(row, () => {
        fillForm(document.querySelector(form), transform(item));
        setEditing(document.querySelector(form), item);
      });
      if (table === "#activity-rows") {
        row.dataset.id = item.id;
        const handle = document.createElement("button");
        handle.type = "button";
        handle.className = "drag-handle";
        handle.textContent = "☰";
        handle.setAttribute("aria-label", `拖曳排序：${item.title}`);
        const handleCell = cell(row, "");
        handleCell.className = "drag-col";
        handleCell.append(handle);
      }
      rows.append(row);
    }
  }
}

function renderReference() {
  fillForm(document.querySelector("#settings-form"), {
    ...reference.settings,
    registration_deadline_at: taipeiInput(reference.settings.registration_deadline_at),
  }, false);
  const staffDistricts = document.querySelector('#create-staff-form select[name="district_id"]');
  staffDistricts.replaceChildren(new Option("未指定", ""));
  for (const district of reference.districts) {
    staffDistricts.add(new Option(district.name, district.id));
  }
  renderReferenceRows();
  renderNewRegistrationForm();
}

async function saveReference(event, kind) {
  event.preventDefault();
  const form = event.currentTarget;
  const data = Object.fromEntries(new FormData(form));
  if (form.dataset.editingId) data.id = form.dataset.editingId;
  for (const name of ["is_registration_open", "is_lookup_open", "is_published", "is_visible"]) {
    if (form.elements.namedItem(name)) data[name] = form.elements.namedItem(name).checked;
  }
  if (kind === "settings") data.registration_deadline_at = taipeiTimestamp(data.registration_deadline_at);
  if (kind === "activity") {
    data.starts_at = taipeiTimestamp(data.starts_at);
    data.ends_at = taipeiTimestamp(data.ends_at);
  }
  // An activity save would change the list being reordered; other saves leave the drag order alone.
  if (kind === "activity" && activitySection.classList.contains("reordering")) {
    return showMessage("請先完成或取消活動排序，再儲存活動。", true);
  }
  if (kind === "settings" && data.is_registration_open && !reference.settings.is_registration_open
    && !confirm("確定開放登記？請先完成正式環境驗收與核准。")) return;
  try {
    await api("save_reference", { kind, data });
    reference = await api("list_reference");
    renderReference();
    if (kind !== "settings") form.reset();
    showMessage("設定已儲存。");
  } catch (error) { showMessage(error.message, true); }
}

async function loadRegistrations() {
  const result = await api("list_registrations", { page, search });
  count = result.count ?? 0;
  document.querySelector("#registration-count").textContent = `共 ${count} 筆`;
  document.querySelector("#page-number").textContent = `第 ${page + 1} 頁`;
  document.querySelector("#previous-page").disabled = page === 0;
  document.querySelector("#next-page").disabled = (page + 1) * 100 >= count;
  const rows = document.querySelector("#registration-rows");
  rows.replaceChildren();
  visibleRegistrations = result.registrations;
  const districtNames = new Map(reference.districts.map((district) => [district.id, district.name]));
  for (const registration of result.registrations) {
    const row = document.createElement("tr");
    cell(row, registration.serial_no);
    cell(row, registration.full_name);
    cell(row, districtNames.get(registration.district_id));
    statusCell(row, "record", registration.record_status);
    statusCell(row, "import", registration.import_status);
    cell(row, shortTime(registration.updated_at));
    const actions = cell(row, "");
    const edit = document.createElement("button");
    edit.type = "button";
    edit.textContent = "查看／處理";
    edit.addEventListener("click", () => openRegistration(registration));
    actions.append(edit);
    rows.append(row);
  }
}

async function allRegistrations() {
  const records = [];
  let beforeSerial = Number.MAX_SAFE_INTEGER;
  while (true) {
    const { registrations } = await api("list_registrations", { page: 0, search: "", before_serial: beforeSerial });
    records.push(...registrations);
    if (registrations.length < 500) return records;
    beforeSerial = registrations.at(-1).serial_no;
  }
}

function activeRegistrations(registrations) {
  return registrations.filter((item) => item.record_status === "active");
}

function currentActivities() {
  return reference.activities.filter((item) => item.is_published);
}

// Returns [參加, 不參加, 未回覆] counts for one activity.
function countAnswers(registrations, activity) {
  const counts = [0, 0, 0];
  for (const registration of registrations) {
    const choice = registration.registration_choices.find((item) => item.activity_id === activity.id);
    counts[!choice ? 2 : choice.attending ? 0 : 1] += 1;
  }
  return counts;
}

async function showStatistics() {
  const registrations = activeRegistrations(await allRegistrations());
  const rows = document.querySelector("#stats-rows");
  rows.replaceChildren();
  let totalFee = 0;
  for (const activity of currentActivities()) {
    const [attending, notAttending, unanswered] = countAnswers(registrations, activity);
    const fee = attending * (activity.fee_amount ?? 0);
    totalFee += fee;
    const row = document.createElement("tr");
    for (const value of [activity.title, attending, notAttending, unanswered, `NT$${fee}`]) cell(row, value);
    rows.append(row);
  }
  document.querySelector("#stats-summary").textContent = `有效登記 ${registrations.length} 筆；預估費用 NT$${totalFee}。`;
  const districtRows = document.querySelector("#district-stats-rows");
  districtRows.replaceChildren();
  const fees = new Map(currentActivities().map((activity) => [activity.id, activity.fee_amount ?? 0]));
  for (const district of reference.districts) {
    const people = registrations.filter((item) => item.district_id === district.id);
    const fee = people.reduce((sum, person) => sum + person.registration_choices.reduce((personFee, choice) =>
      personFee + (choice.attending ? fees.get(choice.activity_id) ?? 0 : 0), 0), 0);
    const row = document.createElement("tr");
    for (const value of [district.name, people.length, `NT$${fee}`]) cell(row, value);
    districtRows.append(row);
  }
  const districtActivityRows = document.querySelector("#district-activity-stats-rows");
  districtActivityRows.replaceChildren();
  for (const district of reference.districts) {
    const people = registrations.filter((item) => item.district_id === district.id);
    for (const activity of currentActivities()) {
      const row = document.createElement("tr");
      for (const value of [district.name, activity.title, ...countAnswers(people, activity)]) cell(row, value);
      districtActivityRows.append(row);
    }
  }
}

function csvCell(value) {
  let text = String(value ?? "").replaceAll(/[\r\n\t]/g, " ");
  if (/^\s*[=+@-]/.test(text)) text = `'${text}`;
  return `"${text.replaceAll('"', '""')}"`;
}

async function downloadCsv() {
  const activities = currentActivities();
  const districts = new Map(reference.districts.map((item) => [item.id, item.name]));
  const rows = [["流水號", "姓名", "區", "匯入狀態", ...activities.map((item) => item.title)]];
  for (const registration of activeRegistrations(await allRegistrations())) {
    const choices = new Map(registration.registration_choices.map((item) => [item.activity_id, item.attending]));
    rows.push([
      registration.serial_no, registration.full_name, districts.get(registration.district_id),
      label("import", registration.import_status),
      ...activities.map((item) => !choices.has(item.id) ? "未回覆" : choices.get(item.id) ? "參加" : "不參加"),
    ]);
  }
  const csv = `\uFEFF${rows.map((row) => row.map(csvCell).join(",")).join("\r\n")}`;
  const url = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = "registration-export.csv";
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

// A new registration answers every activity. An edit only has to keep existing answers:
// an activity the person never answered stays 未回覆 until they choose (requireAll = false).
function renderChoiceFields(container, choices = new Map(), requireAll = true) {
  container.replaceChildren();
  for (const activity of currentActivities()) {
    const item = document.createElement("div");
    item.className = "staff-choice";
    const title = document.createElement("strong");
    title.textContent = activity.title;
    item.append(title);
    if (!requireAll && !choices.has(activity.id)) item.append("（未回覆，可留空）");
    for (const [value, label] of [["true", "參加"], ["false", "不參加"]]) {
      const option = document.createElement("label");
      const radio = document.createElement("input");
      radio.type = "radio";
      radio.name = `activity_${activity.id}`;
      radio.value = value;
      radio.required = requireAll || choices.has(activity.id);
      radio.checked = choices.get(activity.id) === (value === "true");
      option.append(radio, label);
      item.append(option);
    }
    container.append(item);
  }
}

// Redrawn whenever districts or activities change, so it keeps what staff already entered.
function renderNewRegistrationForm() {
  const form = document.querySelector("#new-registration-form");
  const entered = new FormData(form);
  const districts = form.elements.district_id;
  districts.replaceChildren(new Option("請選擇", ""));
  for (const district of reference.districts) {
    districts.add(new Option(district.name, district.id));
  }
  districts.value = entered.get("district_id") ?? "";
  const choices = new Map(choicesFromForm(entered).map((item) => [item.activity_id, item.attending]));
  renderChoiceFields(document.querySelector("#new-registration-choices"), choices);
}

function choicesFromForm(data) {
  return currentActivities().filter((activity) => data.get(`activity_${activity.id}`) !== null)
    .map((activity) => ({ activity_id: activity.id, attending: data.get(`activity_${activity.id}`) === "true" }));
}

function openRegistration(registration) {
  selectedRegistration = registration;
  const detail = document.querySelector("#registration-detail");
  detail.hidden = false;
  document.querySelector("#detail-title").textContent = `登記 #${registration.serial_no}｜${registration.full_name}`;
  const form = document.querySelector("#edit-registration-form");
  form.elements.full_name.value = registration.full_name;
  const districts = form.elements.district_id;
  districts.replaceChildren();
  for (const district of reference.districts) {
    const option = document.createElement("option");
    option.value = district.id;
    option.textContent = district.name;
    option.selected = district.id === registration.district_id;
    districts.append(option);
  }
  const choices = new Map(registration.registration_choices.map((choice) => [choice.activity_id, choice.attending]));
  renderChoiceFields(document.querySelector("#detail-choices"), choices, false);
  document.querySelector("#import-form").elements.status.value = registration.import_status;
  // Only active rows can be edited; a historical cancelled row can still be voided.
  const isActive = registration.record_status === "active";
  form.querySelectorAll("input, select, button").forEach((control) => control.disabled = !isActive);
  const voidForm = document.querySelector("#void-form");
  voidForm.reset();
  voidForm.querySelectorAll("input, button").forEach((control) => control.disabled = registration.record_status === "void");
  detail.scrollIntoView({ behavior: "smooth", block: "start" });
}

async function refreshRegistration() {
  await loadRegistrations();
  const updated = visibleRegistrations.find((item) => item.id === selectedRegistration?.id);
  if (updated) openRegistration(updated);
  else document.querySelector("#registration-detail").hidden = true;
}

async function loadStaff() {
  const { staff } = await api("list_staff");
  const rows = document.querySelector("#staff-rows");
  rows.replaceChildren();
  for (const person of staff) {
    const row = document.createElement("tr");
    cell(row, person.username);
    cell(row, person.display_name);
    cell(row, label("role", person.role));
    cell(row, person.is_active ? "啟用" : "停用");
    cell(row, person.must_change_password ? "待更改" : "已更改");
    const actions = cell(row, "");
    const reset = document.createElement("button");
    reset.type = "button";
    reset.textContent = "重設密碼";
    reset.addEventListener("click", () => changeStaff(person, "reset_staff_password"));
    const toggle = document.createElement("button");
    toggle.type = "button";
    toggle.textContent = person.is_active ? "停用" : "啟用";
    toggle.addEventListener("click", () => changeStaff(person, "set_staff_active"));
    if (person.auth_user_id === profile.auth_user_id) actions.append(toggle);
    else actions.append(reset, toggle);
    rows.append(row);
  }
}

async function changeStaff(person, action) {
  if (!confirm(`確定要${action === "reset_staff_password" ? "重設密碼" : person.is_active ? "停用" : "啟用"} ${person.username}？`)) return;
  try {
    const result = await api(action, { user_id: person.auth_user_id, is_active: !person.is_active });
    if (result.password) {
      const notice = document.querySelector("#temporary-password");
      notice.textContent = `一次性初始密碼：${result.password}。請立即以安全方式交付；離開頁面後無法再次查看。`;
      notice.hidden = false;
    }
    await loadStaff();
    showMessage("帳號已更新。");
  } catch (error) { showMessage(error.message, true); }
}

async function openStaff() {
  const result = await api("me");
  profile = result.profile;
  loginPanel.hidden = true;
  changePasswordPanel.hidden = !profile.must_change_password;
  staffPanel.hidden = profile.must_change_password;
  document.querySelector("#identity").textContent = `${profile.display_name}｜${label("role", profile.role)}`;
  if (profile.must_change_password) return;
  const isAdmin = profile.role === "admin";
  showAdminSections(false);
  reference = await api("list_reference");
  // renderReference also builds the new-registration form, so it runs once either way.
  if (isAdmin) renderReference();
  else renderNewRegistrationForm();
  await Promise.all([loadRegistrations(), ...(isAdmin ? [loadStaff()] : [])]);
  showAdminSections(isAdmin);
}

for (const [selector, kind] of [
  ["#settings-form", "settings"], ["#district-form", "district"],
  ["#activity-form", "activity"], ["#program-form", "program"],
]) {
  const form = document.querySelector(selector);
  form.addEventListener("submit", (event) => saveReference(event, kind));
  if (kind !== "settings") form.addEventListener("reset", () => setEditing(form, null));
}

// Activity order: a toggle shows the ☰ column; dragging (mouse or touch, via Pointer Events,
// which work on iOS Safari unlike HTML drag and drop) or ↑/↓ on a handle moves rows, and
// "完成排序" saves the whole order at once.
const activitySection = document.querySelector("#admin-activities");
const activityRows = document.querySelector("#activity-rows");
const reorderButton = document.querySelector("#reorder-activities");
const cancelReorderButton = document.querySelector("#cancel-reorder");
const staffNav = document.querySelector(".staff-nav");
let activityOrderBefore = "";
let endDrag = null;

const activityOrder = () => Array.from(activityRows.rows, (row) => Number(row.dataset.id));

function setReordering(on) {
  // A drag still running would move a row that a redraw has already replaced.
  endDrag?.();
  activitySection.classList.toggle("reordering", on);
  reorderButton.textContent = on ? "完成排序" : "調整排序";
  reorderButton.classList.toggle("secondary", !on);
  cancelReorderButton.hidden = !on;
  document.querySelector("#reorder-hint").hidden = !on;
  for (const button of activityRows.querySelectorAll("button:not(.drag-handle)")) button.disabled = on;
}

reorderButton.addEventListener("click", async () => {
  if (!activitySection.classList.contains("reordering")) {
    activityOrderBefore = JSON.stringify(activityOrder());
    setReordering(true);
    return;
  }
  const order = activityOrder();
  if (JSON.stringify(order) === activityOrderBefore) return setReordering(false);
  // 取消 also waits, so it cannot put back the old order on screen while the new one is being saved.
  reorderButton.disabled = cancelReorderButton.disabled = true;
  try {
    await api("reorder_activities", { activity_ids: order });
  } catch (error) {
    if (error.status !== 409) return showMessage(error.message, true);
    // The list changed elsewhere; retrying or 取消 would keep using the stale list, so reload it.
    try {
      reference.activities = (await api("list_reference")).activities;
    } catch (reloadError) {
      return showMessage(`${error.message}（重新載入失敗：${reloadError.message}）`, true);
    }
    setReordering(false);
    renderReferenceRows("#activity-rows");
    renderNewRegistrationForm();
    return showMessage("活動清單已有變動，已重新載入，請再調整一次排序。", true);
  } finally {
    reorderButton.disabled = cancelReorderButton.disabled = false;
  }
  // The server numbers activities 1, 2, 3... in the order sent, so update the local copy
  // instead of reloading everything.
  const byId = new Map(reference.activities.map((item) => [item.id, item]));
  reference.activities = order.map((id, index) => ({ ...byId.get(id), sort_order: index + 1 }));
  setReordering(false);
  renderReferenceRows("#activity-rows");
  renderNewRegistrationForm();
  // An open activity edit still holds the old sort_order and would undo this order when saved.
  const activityForm = document.querySelector("#activity-form");
  const position = order.indexOf(Number(activityForm.dataset.editingId)) + 1;
  if (position) activityForm.elements.sort_order.value = position;
  showMessage("活動排序已儲存。");
});

cancelReorderButton.addEventListener("click", () => {
  renderReferenceRows("#activity-rows");
  setReordering(false);
});

activityRows.addEventListener("pointerdown", (event) => {
  const handle = event.target.closest(".drag-handle");
  // Only the first finger or the main mouse button drags; a second finger or a right-click does not.
  if (!handle || !activitySection.classList.contains("reordering") || !event.isPrimary || event.button !== 0) return;
  event.preventDefault();
  endDrag?.();
  const row = handle.closest("tr");
  row.classList.add("dragging");
  let clientX;
  let clientY;
  // The sticky navigation bar covers the top of the page on desktop, so its bottom is the top edge.
  const topEdge = () => Math.max(0, staffNav.getBoundingClientRect().bottom);
  const place = () => {
    const y = Math.max(clientY, topEdge() + 1);
    const target = document.elementFromPoint(clientX, y)?.closest("#activity-rows tr");
    if (!target || target === row) return;
    const { top, height } = target.getBoundingClientRect();
    activityRows.insertBefore(row, y < top + height / 2 ? target : target.nextElementSibling);
  };
  // touch-action: none stops the finger from scrolling, so scroll while the pointer rests near
  // the top or bottom edge; otherwise a row could only reach positions already on screen.
  let frame;
  const autoScroll = () => {
    const edge = 56;
    const step = clientY === undefined ? 0 : clientY < topEdge() + edge ? -10 : clientY > window.innerHeight - edge ? 10 : 0;
    if (step) {
      window.scrollBy(0, step);
      place();
    }
    frame = requestAnimationFrame(autoScroll);
  };
  frame = requestAnimationFrame(autoScroll);
  // Listen on window: pointer capture is not reliable across browsers, and a missed capture would
  // send moves to whatever element is under the pointer instead of this handle.
  const finish = () => {
    cancelAnimationFrame(frame);
    row.classList.remove("dragging");
    window.removeEventListener("pointermove", move);
    window.removeEventListener("pointerup", end);
    window.removeEventListener("pointercancel", end);
    window.removeEventListener("blur", finish);
    endDrag = null;
  };
  const move = (moveEvent) => {
    if (moveEvent.pointerId !== event.pointerId) return;
    // A release outside the window may never send pointerup; no button held means the drag is over.
    if (moveEvent.buttons === 0) return finish();
    ({ clientX, clientY } = moveEvent);
    place();
  };
  const end = (endEvent) => {
    if (endEvent.pointerId === event.pointerId) finish();
  };
  endDrag = finish;
  window.addEventListener("pointermove", move);
  window.addEventListener("pointerup", end);
  window.addEventListener("pointercancel", end);
  window.addEventListener("blur", finish);
});

activityRows.addEventListener("keydown", (event) => {
  const handle = event.target.closest(".drag-handle");
  if (!handle || !["ArrowUp", "ArrowDown"].includes(event.key)) return;
  event.preventDefault();
  const row = handle.closest("tr");
  const sibling = event.key === "ArrowUp" ? row.previousElementSibling : row.nextElementSibling;
  if (!sibling) return;
  sibling.insertAdjacentElement(event.key === "ArrowUp" ? "beforebegin" : "afterend", row);
  handle.focus();
});

document.querySelector("#login-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  const username = String(new FormData(form).get("username")).trim().toLowerCase();
  if (!/^[a-z][a-z0-9_-]{2,30}$/.test(username)) return showMessage("請檢查帳號格式", true);
  try {
    await authRequest("token?grant_type=password", { email: `${username}@accounts.invalid`, password: form.elements.password.value });
    form.elements.password.value = "";
    // A message left from before login (for example "請使用新密碼重新登入") no longer applies.
    message.hidden = true;
    await openStaff();
  } catch (error) { showMessage(error.message, true); }
});

document.querySelector("#change-password-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  try {
    await api("change_password", {
      current_password: form.elements.current_password.value, password: form.elements.password.value,
    });
    form.reset();
    clearSession();
    showMessage("密碼已更改，請使用新密碼重新登入。");
  } catch (error) { showMessage(error.message, true); }
});

document.querySelector("#create-staff-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  try {
    const values = Object.fromEntries(new FormData(form));
    values.district_id = values.district_id ? Number(values.district_id) : null;
    const result = await api("create_staff", values);
    form.reset();
    const notice = document.querySelector("#temporary-password");
    notice.textContent = `一次性初始密碼：${result.password}。請立即以安全方式交付；離開頁面後無法再次查看。`;
    notice.hidden = false;
    await loadStaff();
    showMessage("帳號已建立。");
  } catch (error) { showMessage(error.message, true); }
});

// A failed load keeps the previous page and search, so the controls match the rows on screen.
async function showRegistrations(nextPage, nextSearch = search) {
  const previous = [page, search];
  [page, search] = [nextPage, nextSearch];
  try {
    await loadRegistrations();
  } catch (error) {
    [page, search] = previous;
    showMessage(error.message, true);
  }
}
document.querySelector("#search-form").addEventListener("submit", (event) => {
  event.preventDefault();
  showRegistrations(0, String(new FormData(event.currentTarget).get("search")).trim());
});
document.querySelector("#refresh-stats").addEventListener("click", () =>
  showStatistics().catch((error) => showMessage(error.message, true)));
document.querySelector("#download-csv").addEventListener("click", () =>
  downloadCsv().catch((error) => showMessage(error.message, true)));
document.querySelector("#edit-registration-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  const data = new FormData(form);
  const choices = choicesFromForm(data);
  try {
    await api("save_registration", {
      registration_id: selectedRegistration.id, full_name: data.get("full_name"),
      district_id: Number(data.get("district_id")), choices,
    });
    await refreshRegistration();
    showMessage("登記資料已儲存。");
  } catch (error) { showMessage(error.message, true); }
});
// Same form content keeps the same id, so a double submit or network retry cannot create a second record.
let newRegistrationRequestId = crypto.randomUUID();
document.querySelector("#new-registration-form").addEventListener("input", () => {
  newRegistrationRequestId = crypto.randomUUID();
});
document.querySelector("#new-registration-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  const submit = form.querySelector('button[type="submit"]');
  if (submit.disabled) return;
  submit.disabled = true;
  const data = new FormData(form);
  try {
    const result = await api("create_registration", {
      create_request_id: newRegistrationRequestId,
      full_name: data.get("full_name"), district_id: Number(data.get("district_id")),
      choices: choicesFromForm(data),
    });
    newRegistrationRequestId = crypto.randomUUID();
    const notice = document.querySelector("#new-registration-code");
    notice.textContent = `已建立流水號 ${result.serial_no}。本人日後可用相同的姓名與區查詢。`;
    notice.hidden = false;
    form.reset();
    renderNewRegistrationForm();
    await loadRegistrations();
    showMessage("補登已建立。");
  } catch (error) {
    showMessage(error.message, true);
  } finally {
    submit.disabled = false;
  }
});
document.querySelector("#import-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  try {
    await api("set_import_status", {
      registration_id: selectedRegistration.id,
      status: new FormData(event.currentTarget).get("status"),
    });
    await refreshRegistration();
    showMessage("匯入狀態已更新。");
  } catch (error) { showMessage(error.message, true); }
});
document.querySelector("#void-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!confirm("確定作廢此登記？作廢後不計入統計與 CSV，且無法在頁面上恢復。")) return;
  try {
    await api("void_registration", {
      registration_id: selectedRegistration.id,
      reason: String(new FormData(event.currentTarget).get("reason")).trim(),
    });
    await refreshRegistration();
    showMessage("登記已作廢。");
  } catch (error) { showMessage(error.message, true); }
});
document.querySelector("#previous-page").addEventListener("click", () => showRegistrations(page - 1));
document.querySelector("#next-page").addEventListener("click", () => showRegistrations(page + 1));
document.querySelector("#logout-button").addEventListener("click", async () => {
  const token = session?.access_token;
  let remoteError = false;
  try {
    if (token) await fetch(`${config.supabaseUrl}/auth/v1/logout?scope=local`, {
      method: "POST", headers: { apikey: config.publishableKey, Authorization: `Bearer ${token}` },
    });
  } catch {
    remoteError = true;
  } finally {
    clearSession();
    showMessage(remoteError ? "無法確認遠端登出，請關閉此分頁。" : "已登出。", remoteError);
  }
});

// Auth failures already clear the session in api()/accessToken(); a brief outage should not log the user out.
if (session) openStaff().catch((error) => showMessage(error.message, true));
