const config = window.APP_CONFIG;
const message = document.querySelector("#page-message");
const registrationForm = document.querySelector("#registration-form");
const queryForm = document.querySelector("#query-form");
const editForm = document.querySelector("#edit-form");
const editActivities = document.querySelector("#edit-activities");
const editModeHint = document.querySelector("#edit-mode-hint");
const startEditButton = document.querySelector("#start-edit");
const saveEditButton = document.querySelector("#save-edit");
const cancelEditButton = document.querySelector("#cancel-edit");
const hostingSection = document.querySelector("#hosting-section");
const hostingFields = document.querySelector("#hosting-fields");
const editHostingSection = document.querySelector("#edit-hosting-section");
const editHosting = document.querySelector("#edit-hosting");
const hostingClosedMessage = "開家接待調查已關閉，如需調整請聯絡服事者";
const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
const startedAt = Date.now();
let pageData;
// The name and district of the loaded registration; an update sends them back as its lookup key.
let activeIdentity = null;
let queriedChoicesBaseline = null;
let queriedHostingBaseline = null;
let queriedIdentityBaseline = null;
// The edit form as it first appears. Opening it can already turn a restricted activity signed up
// before the restriction into 不參加 (and so hide the identity question); that alone is not an edit
// to warn about, and it is saved only together with a change the person makes.
let editStartChoices = null;
let editStartIdentity = null;
let queriedCanChange = false;
let editMode = false;

if (config?.environment === "test") document.querySelector("#test-banner").hidden = false;
// The success page keeps its summary across reloads; returning here clears it, so the next
// person on a shared device starts without the previous person's details.
sessionStorage.removeItem("registration_success");

function selectTab(tab) {
  const current = tabs.find((item) => item.getAttribute("aria-selected") === "true");
  if (tab !== current && hasUnsavedChanges() && !confirm("確定放棄尚未儲存的修改？")) return false;
  if (tab !== current && editMode) showConfirmation();
  for (const item of tabs) {
    const selected = item === tab;
    item.setAttribute("aria-selected", String(selected));
    item.tabIndex = selected ? 0 : -1;
    document.getElementById(item.getAttribute("aria-controls")).hidden = !selected;
  }
  return true;
}

for (const tab of tabs) {
  tab.addEventListener("click", () => selectTab(tab));
  tab.addEventListener("keydown", (event) => {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const next = event.key === "Home" ? tabs[0]
      : event.key === "End" ? tabs.at(-1)
      : tabs[(tabs.indexOf(tab) + (event.key === "ArrowRight" ? 1 : -1) + tabs.length) % tabs.length];
    if (selectTab(next)) next.focus();
  });
}

function showMessage(text, error = false) {
  message.textContent = text;
  message.classList.toggle("error", error);
  message.hidden = false;
  message.scrollIntoView({ behavior: "smooth", block: "center" });
}

function taipeiDateTime(value) {
  if (!value) return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return null;
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-US", {
    timeZone: "Asia/Taipei", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).formatToParts(date).map((part) => [part.type, part.value]));
  return {
    day: `${parts.year}-${parts.month}-${parts.day}`,
    date: `${Number(parts.month)}/${Number(parts.day)}`,
    time: `${parts.hour}:${parts.minute}`,
  };
}

function activityTime(activity) {
  const start = taipeiDateTime(activity.starts_at);
  if (!start) return "";
  const startText = activity.starts_at_has_time === false ? start.date : `${start.date} ${start.time}`;
  const end = taipeiDateTime(activity.ends_at);
  if (!end) return startText;
  if (end.day === start.day && activity.starts_at_has_time === false && activity.ends_at_has_time === false) {
    return startText;
  }
  const bothTimesOnSameDay = end.day === start.day
    && activity.starts_at_has_time !== false && activity.ends_at_has_time !== false;
  const endText = bothTimesOnSameDay ? end.time
    : (activity.ends_at_has_time === false ? end.date : `${end.date} ${end.time}`);
  return `${startText}–${endText}`;
}

async function api(body) {
  if (!config?.supabaseUrl || !config?.publishableKey) throw new Error("網站尚未設定 Supabase 公開連線資訊");
  const response = await fetch(`${config.supabaseUrl}/functions/v1/registration`, {
    method: body ? "POST" : "GET",
    headers: { apikey: config.publishableKey, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = new Error(result.error || "服務暫時無法使用");
    error.status = response.status;
    error.code = result.code;
    error.body = result;
    throw error;
  }
  return result;
}

// Only http(s) links open; anything else (javascript:, typos) is left out rather than shown broken.
function mapLink(value) {
  let url;
  try { url = new URL(value); } catch { return ""; }
  if (url.protocol !== "https:" && url.protocol !== "http:") return "";
  const href = escapeHtml(url.href).replaceAll('"', "&quot;");
  return `<p class="hint"><a href="${href}" target="_blank" rel="noopener noreferrer">查看地圖</a></p>`;
}

// The query tab leaves out the map link; it is only for people deciding to register.
function activityDetails(activity, showMap = true) {
    const time = activityTime(activity);
    return `<strong>${escapeHtml(activity.title)}</strong>
      ${time ? `<p class="hint">時間：${escapeHtml(time)}</p>` : ""}
      ${activity.venue ? `<p class="hint">地點：${escapeHtml(activity.venue)}</p>` : ""}
      ${activity.address ? `<p class="hint">地址：${escapeHtml(activity.address)}</p>` : ""}
      ${showMap && activity.map_url ? mapLink(activity.map_url) : ""}
      ${Meals.feeText(activity) ? `<p class="hint">${escapeHtml(Meals.feeText(activity))}</p>` : ""}
      ${activity.description ? `<p class="hint">${escapeHtml(activity.description)}</p>` : ""}`;
}

function activityFields(activities, values = new Map(), showMap = true) {
  return activities.map((activity) => {
    const selected = values.get(activity.id);
    return `<div class="activity" data-activity="${activity.id}">
      ${activityDetails(activity, showMap)}
      <div class="activity-options">
        <label><input type="radio" name="activity_${activity.id}" value="true" ${selected === true ? "checked" : ""} required>參加</label>
        <label><input type="radio" name="activity_${activity.id}" value="false" ${selected === false ? "checked" : ""} required>不參加</label>
      </div>
    </div>`;
  }).join("");
}

function activitySummaryFields(activities, values) {
  return activities.map((activity) => {
    const selected = values.get(activity.id);
    const status = selected === true ? "參加" : selected === false ? "不參加" : "未回覆";
    return `<div class="activity">
      ${activityDetails(activity, false)}
      <p class="activity-status">登記狀態：${status}</p>
    </div>`;
  }).join("");
}

function escapeHtml(value) {
  const element = document.createElement("span");
  element.textContent = String(value ?? "");
  return element.innerHTML;
}

function showProgram(program) {
  const section = document.querySelector("#program-section");
  section.hidden = program.length === 0;
  const days = new Map();
  for (const item of program) {
    if (!days.has(item.event_date)) days.set(item.event_date, []);
    days.get(item.event_date).push(item);
  }
  document.querySelector("#program").innerHTML = Array.from(days, ([date, items]) => {
    const day = new Intl.DateTimeFormat("zh-TW", {
      timeZone: "Asia/Taipei", month: "long", day: "numeric", weekday: "long",
    }).format(new Date(`${date}T00:00:00+08:00`));
    return `<section class="program-day" aria-label="${escapeHtml(day)}">
      <h3>${escapeHtml(day)}</h3>
      <div class="program-slots">${items.map((item) => {
        const start = item.start_time?.slice(0, 5);
        const end = item.end_time?.slice(0, 5);
        const time = start ? `${start}${end ? `–${end}` : ""}` : "時間待定";
        return `<div class="program-slot">
          <time>${escapeHtml(time)}</time>
          <div><strong>${escapeHtml(item.title)}</strong>${item.note ? `<p>${escapeHtml(item.note)}</p>` : ""}</div>
        </div>`;
      }).join("")}</div>
    </section>`;
  }).join("");
}

function districtOptions(districts) {
  return `<option value="">請選擇</option>${districts.map((district) =>
    `<option value="${district.id}">${escapeHtml(district.name)}</option>`
  ).join("")}`;
}

function choicesFrom(form) {
  const choices = Meals.choices(form, pageData.activities);
  if (choices.length !== pageData.activities.length) throw new Error("請回答每一項活動");
  return choices;
}

function sortedChoices(choices) {
  return choices
    .map((choice) => ({ activity_id: Number(choice.activity_id), attending: choice.attending }))
    .sort((left, right) => left.activity_id - right.activity_id);
}

function choicesMap(choices) {
  return new Map(choices.map((choice) => [Number(choice.activity_id), choice.attending]));
}

function currentEditChoices() {
  const answered = choicesMap(Meals.choices(editForm, pageData.activities));
  return sortedChoices(pageData.activities.map((activity) => ({
    activity_id: activity.id, attending: answered.has(activity.id) ? answered.get(activity.id) : null,
  })));
}

const hostingOpen = () => Boolean(pageData?.settings.is_hosting_open);

const currentEditIdentity = () => editMode ? Meals.readIdentity(editActivities) : queriedIdentityBaseline;
const checkedHostingStatus = (container) => container.querySelector('[name="hosting_status"]:checked')?.value ?? null;

// Restricted activities follow the 開家接待 answer on screen (or the stored one while it cannot be
// edited); the identity question follows the student-priced meals chosen.
function syncMeals() {
  Meals.sync(registrationForm, pageData.activities, hostingOpen() ? checkedHostingStatus(hostingFields) : null);
  if (editMode) {
    Meals.sync(editActivities, pageData.activities,
      hostingOpen() ? checkedHostingStatus(editHosting) : queriedHostingBaseline?.status ?? null);
  }
}

// Only an open hosting survey is editable by the registrant; otherwise the stored answer stands.
function currentEditHosting() {
  return editMode && hostingOpen() ? Hosting.read(editHosting) : queriedHostingBaseline;
}

function hasUnsavedChanges() {
  return Boolean(editMode && editStartChoices
    && (JSON.stringify(currentEditChoices()) !== JSON.stringify(editStartChoices)
      || JSON.stringify(currentEditHosting()) !== JSON.stringify(queriedHostingBaseline)
      || currentEditIdentity() !== editStartIdentity
      // Pickup can be chosen before the first question, which read() does not report yet.
      || (hostingOpen() && Number(editHosting.querySelector('[name="pickup_count"]')?.value
        ?? queriedHostingBaseline?.pickup_count ?? 0) !== (queriedHostingBaseline?.pickup_count ?? 0))));
}

function updateSaveState() {
  saveEditButton.disabled = !editForm.checkValidity() || !hasUnsavedChanges();
}

// The hosting description: on the registration form while hosting is open, and in the lookup only
// while editing, since the confirmation and read-only views cannot answer it.
function showHostingDescriptions() {
  const text = hostingOpen() ? pageData.settings.hosting_description ?? "" : "";
  for (const [element, visible] of [[hostingSection, true], [editHostingSection, editMode]]) {
    const description = element.querySelector(".hosting-description");
    description.textContent = text;
    description.hidden = !(visible && text);
  }
}

// Shows the registration form's hosting fields while hosting is open. When closed the fields are
// removed, not just hidden, so their required radios cannot block the form. Also refreshes both
// descriptions (see showHostingDescriptions).
function showRegistrationHosting() {
  showHostingDescriptions();
  hostingSection.hidden = !hostingOpen();
  if (!hostingOpen()) {
    hostingFields.replaceChildren();
    delete hostingFields.dataset.hosting;
    return;
  }
  if (hostingFields.dataset.hosting === undefined) Hosting.render(hostingFields);
}

// The switch changed after this page loaded (HOSTING_CLOSED / HOSTING_REQUIRED from the server).
// Shows what happened; unsaved activity edits stay as they are.
// HOSTING_REQUIRED carries the current description, which the admin may have written meanwhile.
function applyHostingChange(error) {
  pageData.settings.is_hosting_open = error.code === "HOSTING_REQUIRED";
  if (error.body?.hosting_description !== undefined) pageData.settings.hosting_description = error.body.hosting_description;
  showRegistrationHosting();
  if (editMode) {
    if (hostingOpen()) {
      editHostingSection.hidden = false;
      // Fields already on screen keep what the person typed.
      if (editHosting.dataset.hosting === undefined) Hosting.render(editHosting, queriedHostingBaseline);
    } else {
      showHostingSummary();
    }
  } else if (queriedChoicesBaseline) {
    // A lookup shown in the other tab keeps its hosting summary and hint in step with the switch.
    showHostingSummary();
  }
  // Restricted activities now follow the answer that stands after the switch.
  syncMeals();
  // Only the hosting answer had changed: nothing is left to save.
  if (editMode && !hostingOpen() && !hasUnsavedChanges()) {
    showConfirmation();
    // Nothing was lost and the page is back to a normal confirmation, so this is not an error.
    return showMessage("開家接待調查已關閉，接待內容維持原樣。");
  }
  const button = editMode ? "「儲存修改」" : "「送出登記」";
  if (hostingOpen()) return showMessage(`開家接待調查已開放，請回答開家接待後再按${button}。`, true);
  // A new registration had nothing stored, so its answer is dropped, not kept.
  return showMessage(editMode ? "開家接待調查已關閉，接待內容維持原樣，請再按一次「儲存修改」。"
    : "開家接待調查已關閉，接待回答不會送出；請再按一次「送出登記」。", true);
}

// While hosting is closed an existing answer stays visible but read-only; without one the section stays hidden.
function showHostingSummary() {
  const answer = queriedHostingBaseline;
  editHostingSection.hidden = !hostingOpen() && !answer;
  delete editHosting.dataset.hosting;
  editHosting.innerHTML = `<p class="activity-status">登記狀態：${escapeHtml(Hosting.summary(answer))}</p>
    ${hostingOpen() ? "" : `<p class="hint">${hostingClosedMessage}</p>`}`;
}

function showConfirmation() {
  editMode = false;
  editActivities.innerHTML = activitySummaryFields(pageData.activities, choicesMap(queriedChoicesBaseline ?? []));
  if (queriedIdentityBaseline) {
    editActivities.insertAdjacentHTML("beforeend", `<div class="activity"><strong>用餐身分</strong>
      <p class="activity-status">登記狀態：${escapeHtml(Meals.identityLabels[queriedIdentityBaseline])}</p></div>`);
  }
  showHostingSummary();
  showHostingDescriptions();
  editModeHint.hidden = true;
  startEditButton.hidden = !queriedCanChange;
  startEditButton.disabled = false;
  saveEditButton.hidden = true;
  cancelEditButton.hidden = true;
}

function beginEditing() {
  if (!queriedCanChange || !queriedChoicesBaseline) return;
  editMode = true;
  editActivities.innerHTML = activityFields(pageData.activities, choicesMap(queriedChoicesBaseline), false);
  Meals.render(editActivities, pageData.activities, queriedIdentityBaseline);
  if (hostingOpen()) Hosting.render(editHosting, queriedHostingBaseline);
  syncMeals();
  editStartChoices = currentEditChoices();
  editStartIdentity = currentEditIdentity();
  showHostingDescriptions();
  editModeHint.hidden = false;
  startEditButton.hidden = true;
  saveEditButton.hidden = false;
  cancelEditButton.hidden = false;
  updateSaveState();
  editActivities.querySelector("input")?.focus();
}

function districtName(id) {
  return pageData.districts.find((district) => String(district.id) === String(id))?.name ?? "";
}

function setBusy(form, busy) {
  form.querySelectorAll("button").forEach((button) => button.disabled = busy);
}

// Built from text nodes so the admin's note can never become markup; only https:// links are clickable.
// A bare link is ASCII URL characters only, so Chinese text written right after it stays text, and a
// trailing . , ; : ! ? ends the sentence, not the link. [label](https://...) shows the label as the link.
const noteLinkPattern = /\[([^\[\]\n]{1,200})\]\((https:\/\/[^\s()]+)\)|(https:\/\/[\w\-.~:/?#[\]@!$&*+,;=%]*[\w\-~/#[\]@$&*+=%])/g;

function showEventNote(text) {
  const note = document.querySelector("#event-note");
  const value = String(text ?? "");
  const parts = [];
  let last = 0;
  for (const match of value.matchAll(noteLinkPattern)) {
    parts.push(document.createTextNode(value.slice(last, match.index)));
    const link = document.createElement("a");
    link.href = match[2] ?? match[3];
    link.textContent = match[1] ?? match[3];
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    parts.push(link);
    last = match.index + match[0].length;
  }
  parts.push(document.createTextNode(value.slice(last)));
  note.replaceChildren(...parts);
  note.hidden = !text;
}

async function loadPage() {
  try {
    pageData = await api();
    document.querySelector("#event-name").textContent = pageData.settings.event_name;
    document.querySelector("#event-meta").textContent = [pageData.settings.venue, pageData.settings.address].filter(Boolean).join("｜");
    showEventNote(pageData.settings.event_note);
    showProgram(pageData.program);
    registrationForm.elements.district_id.innerHTML = districtOptions(pageData.districts);
    queryForm.elements.district_id.innerHTML = districtOptions(pageData.districts);
    document.querySelector("#activities").innerHTML = activityFields(pageData.activities);
    Meals.render(document.querySelector("#activities"), pageData.activities);
    showRegistrationHosting();
    syncMeals();
    if (!pageData.settings.is_registration_open || pageData.activities.length === 0) {
      registrationForm.querySelector("button[type=submit]").disabled = true;
      showMessage("登記目前尚未開放。", true);
    }
  } catch (error) {
    registrationForm.hidden = true;
    queryForm.hidden = true;
    showMessage(error.message, true);
  }
}

registrationForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  setBusy(registrationForm, true);
  try {
    const data = new FormData(registrationForm);
    const choices = choicesFrom(registrationForm);
    const hosting = hostingOpen() ? Hosting.read(hostingFields) : undefined;
    const mealIdentity = Meals.readIdentity(registrationForm);
    await api({
      action: "create",
      create_request_id: crypto.randomUUID(),
      started_at: startedAt,
      website: data.get("website"),
      full_name: data.get("full_name"),
      district_id: Number(data.get("district_id")),
      choices,
      hosting,
      // Sent only when asked; the server treats a missing identity as no answer.
      meal_identity: mealIdentity ?? undefined,
      turnstile_token: null,
    });
    // The success page shows what was sent, so the person can check it before leaving.
    sessionStorage.setItem("registration_success", JSON.stringify({
      full_name: String(data.get("full_name")).trim(),
      district: districtName(data.get("district_id")),
      choices: choices.map((choice) => ({
        title: pageData.activities.find((activity) => activity.id === choice.activity_id)?.title ?? "",
        attending: choice.attending,
      })),
      hosting: hosting ? `開家接待：${Hosting.summary(hosting)}` : null,
      meal_identity: mealIdentity ? `用餐身分：${Meals.identityLabels[mealIdentity]}` : null,
    }));
    location.assign("./success.html");
  } catch (error) {
    if (["HOSTING_CLOSED", "HOSTING_REQUIRED"].includes(error.code)) return applyHostingChange(error);
    showMessage(error.message, true);
  } finally {
    setBusy(registrationForm, false);
  }
});

queryForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (hasUnsavedChanges() && !confirm("確定放棄尚未儲存的修改？")) return;
  setBusy(queryForm, true);
  editForm.hidden = true;
  activeIdentity = null;
  queriedChoicesBaseline = null;
  queriedHostingBaseline = null;
  queriedIdentityBaseline = null;
  queriedCanChange = false;
  editMode = false;
  try {
    const data = new FormData(queryForm);
    const identity = { full_name: String(data.get("full_name")).trim(), district_id: Number(data.get("district_id")) };
    const registration = await api({ action: "query", ...identity });
    document.querySelector("#edit-identity").textContent = `${registration.full_name}｜${districtName(registration.district_id)}`;
    activeIdentity = identity;
    queriedChoicesBaseline = sortedChoices(registration.choices);
    queriedHostingBaseline = Hosting.normalize(registration.hosting);
    // An identity left over from a removed student price is neither shown nor kept.
    queriedIdentityBaseline = Meals.identityFor(pageData.activities, queriedChoicesBaseline, registration.meal_identity);
    queriedCanChange = registration.can_change;
    editForm.hidden = false;
    showConfirmation();
    showMessage(registration.can_change
      ? "以下為目前登記內容。"
      : "目前只能查看，無法修改登記內容。");
  } catch (error) {
    editForm.hidden = true;
    showMessage(error.message, true);
  } finally {
    setBusy(queryForm, false);
  }
});

editForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!activeIdentity || !queriedChoicesBaseline) {
    showMessage("請先查詢登記資料。", true);
    return;
  }
  if (!editMode) return;
  const choices = currentEditChoices();
  if (choices.some((choice) => choice.attending === null)) return showMessage("請回答每一項活動", true);
  if (!editForm.reportValidity() || !hasUnsavedChanges()) return;
  const hosting = currentEditHosting();
  const mealIdentity = currentEditIdentity();
  setBusy(editForm, true);
  try {
    await api({ action: "update", ...activeIdentity, choices, meal_identity: mealIdentity ?? undefined,
      ...(hostingOpen() ? { hosting } : {}) });
    queriedChoicesBaseline = choices;
    queriedHostingBaseline = hosting;
    queriedIdentityBaseline = mealIdentity;
    showConfirmation();
    showMessage("修改已儲存，以下為目前登記內容。");
  } catch (error) {
    if (["HOSTING_CLOSED", "HOSTING_REQUIRED"].includes(error.code)) return applyHostingChange(error);
    if (error.status === 409 || error.message === "查詢功能暫停中，請稍後再試") {
      queriedCanChange = false;
      showConfirmation();
    }
    showMessage(error.message, true);
  } finally {
    setBusy(editForm, false);
    if (editMode) updateSaveState();
  }
});

startEditButton.addEventListener("click", beginEditing);
registrationForm.addEventListener("input", syncMeals);
editForm.addEventListener("input", () => {
  if (!editMode) return;
  syncMeals();
  updateSaveState();
});
cancelEditButton.addEventListener("click", () => {
  if (hasUnsavedChanges() && !confirm("確定放棄尚未儲存的修改？")) return;
  showConfirmation();
  showMessage("以下為目前登記內容。");
});

// A page brought back whole from the back/forward cache keeps typed text, which autocomplete="off"
// does not cover; only the names are cleared, since other fields drive what the form shows.
window.addEventListener("pageshow", (event) => {
  if (!event.persisted) return;
  registrationForm.elements.full_name.value = "";
  queryForm.elements.full_name.value = "";
});

window.addEventListener("beforeunload", (event) => {
  if (!hasUnsavedChanges()) return;
  event.preventDefault();
  event.returnValue = "";
});

loadPage();
