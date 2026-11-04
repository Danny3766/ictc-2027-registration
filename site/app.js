const config = window.APP_CONFIG;
const message = document.querySelector("#page-message");
const registrationForm = document.querySelector("#registration-form");
const queryForm = document.querySelector("#query-form");
const editForm = document.querySelector("#edit-form");
const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
const startedAt = Date.now();
let pageData;
// The name and district of the loaded registration; an update sends them back as its lookup key.
let activeIdentity = null;
let queriedChoicesBaseline = null;

if (config?.environment === "test") document.querySelector("#test-banner").hidden = false;
// The success page keeps its summary across reloads; returning here clears it, so the next
// person on a shared device starts without the previous person's details.
sessionStorage.removeItem("registration_success");

function selectTab(tab) {
  for (const item of tabs) {
    const selected = item === tab;
    item.setAttribute("aria-selected", String(selected));
    item.tabIndex = selected ? 0 : -1;
    document.getElementById(item.getAttribute("aria-controls")).hidden = !selected;
  }
}

for (const tab of tabs) {
  tab.addEventListener("click", () => selectTab(tab));
  tab.addEventListener("keydown", (event) => {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const next = event.key === "Home" ? tabs[0]
      : event.key === "End" ? tabs.at(-1)
      : tabs[(tabs.indexOf(tab) + (event.key === "ArrowRight" ? 1 : -1) + tabs.length) % tabs.length];
    selectTab(next);
    next.focus();
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
  if (!response.ok) throw new Error(result.error || "服務暫時無法使用");
  return result;
}

function activityFields(activities, values = new Map()) {
  return activities.map((activity) => {
    const selected = values.get(activity.id);
    const time = activityTime(activity);
    return `<div class="activity">
      <strong>${escapeHtml(activity.title)}</strong>
      ${time ? `<p class="hint">時間：${escapeHtml(time)}</p>` : ""}
      ${activity.venue ? `<p class="hint">地點：${escapeHtml(activity.venue)}</p>` : ""}
      ${activity.address ? `<p class="hint">地址：${escapeHtml(activity.address)}</p>` : ""}
      ${activity.fee_amount != null ? `<p class="hint">規劃費用：NT$${escapeHtml(activity.fee_amount)}／人</p>` : ""}
      ${activity.description ? `<p class="hint">${escapeHtml(activity.description)}</p>` : ""}
      <div class="activity-options">
        <label><input type="radio" name="activity_${activity.id}" value="true" ${selected === true ? "checked" : ""} required>參加</label>
        <label><input type="radio" name="activity_${activity.id}" value="false" ${selected === false ? "checked" : ""} required>不參加</label>
      </div>
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
  const data = new FormData(form);
  const choices = pageData.activities.map((activity) => {
    const value = data.get(`activity_${activity.id}`);
    if (value === null) throw new Error("請回答每一項活動");
    return { activity_id: activity.id, attending: value === "true" };
  });
  return choices;
}

function sortedChoices(choices) {
  return choices
    .map((choice) => ({ activity_id: Number(choice.activity_id), attending: choice.attending }))
    .sort((left, right) => left.activity_id - right.activity_id);
}

function districtName(id) {
  return pageData.districts.find((district) => String(district.id) === String(id))?.name ?? "";
}

function setBusy(form, busy) {
  form.querySelectorAll("button").forEach((button) => button.disabled = busy);
}

async function loadPage() {
  try {
    pageData = await api();
    document.querySelector("#event-name").textContent = pageData.settings.event_name;
    document.querySelector("#event-meta").textContent = [pageData.settings.venue, pageData.settings.address].filter(Boolean).join("｜");
    showProgram(pageData.program);
    registrationForm.elements.district_id.innerHTML = districtOptions(pageData.districts);
    queryForm.elements.district_id.innerHTML = districtOptions(pageData.districts);
    document.querySelector("#activities").innerHTML = activityFields(pageData.activities);
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
    await api({
      action: "create",
      create_request_id: crypto.randomUUID(),
      started_at: startedAt,
      website: data.get("website"),
      full_name: data.get("full_name"),
      district_id: Number(data.get("district_id")),
      choices,
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
    }));
    location.assign("./success.html");
  } catch (error) {
    showMessage(error.message, true);
  } finally {
    setBusy(registrationForm, false);
  }
});

queryForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  setBusy(queryForm, true);
  editForm.hidden = true;
  activeIdentity = null;
  queriedChoicesBaseline = null;
  try {
    const data = new FormData(queryForm);
    const identity = { full_name: String(data.get("full_name")).trim(), district_id: Number(data.get("district_id")) };
    const registration = await api({ action: "query", ...identity });
    document.querySelector("#edit-identity").textContent = `${registration.full_name}｜${districtName(registration.district_id)}`;
    const values = new Map(registration.choices.map((choice) => [choice.activity_id, choice.attending]));
    document.querySelector("#edit-activities").innerHTML = activityFields(pageData.activities, values);
    activeIdentity = identity;
    queriedChoicesBaseline = sortedChoices(registration.choices.filter((choice) => choice.attending !== null));
    editForm.hidden = false;
    editForm.querySelectorAll("input, select, button").forEach((control) => control.disabled = !registration.can_change);
    showMessage(registration.can_change ? "已載入登記資料。" : "登記已截止，資料只能查看。");
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
  let choices;
  try {
    choices = sortedChoices(choicesFrom(editForm));
  } catch (error) {
    showMessage(error.message, true);
    return;
  }
  if (JSON.stringify(choices) === JSON.stringify(queriedChoicesBaseline)) {
    showMessage("目前內容沒有變更。");
    return;
  }
  setBusy(editForm, true);
  try {
    await api({ action: "update", ...activeIdentity, choices });
    queriedChoicesBaseline = choices;
    showMessage("登記資料已儲存。");
  } catch (error) {
    showMessage(error.message, true);
  } finally {
    setBusy(editForm, false);
  }
});

loadPage();
