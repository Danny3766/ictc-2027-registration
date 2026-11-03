const config = window.APP_CONFIG;
const message = document.querySelector("#page-message");
const registrationForm = document.querySelector("#registration-form");
const queryForm = document.querySelector("#query-form");
const editForm = document.querySelector("#edit-form");
const startedAt = Date.now();
let pageData;
let activeQueryCode = "";

function showMessage(text, error = false) {
  message.textContent = text;
  message.classList.toggle("error", error);
  message.hidden = false;
  message.scrollIntoView({ behavior: "smooth", block: "center" });
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
    return `<div class="activity">
      <strong>${escapeHtml(activity.title)}</strong>
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

function districtOptions(selected = "") {
  return `<option value="">請選擇</option>${pageData.districts.map((district) =>
    `<option value="${district.id}" ${String(district.id) === String(selected) ? "selected" : ""}>${escapeHtml(district.name)}</option>`
  ).join("")}`;
}

function choicesFrom(form) {
  const data = new FormData(form);
  const choices = pageData.activities.map((activity) => {
    const value = data.get(`activity_${activity.id}`);
    if (value === null) throw new Error("請回答每一項活動");
    return { activity_id: activity.id, attending: value === "true" };
  });
  if (!choices.some((choice) => choice.attending)) throw new Error("請至少選擇參加一項活動");
  return choices;
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
    registrationForm.elements.district_id.innerHTML = districtOptions();
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
    const result = await api({
      action: "create",
      create_request_id: crypto.randomUUID(),
      started_at: startedAt,
      website: data.get("website"),
      full_name: data.get("full_name"),
      district_id: Number(data.get("district_id")),
      choices: choicesFrom(registrationForm),
      turnstile_token: null,
    });
    sessionStorage.setItem("registration_success", JSON.stringify(result));
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
  try {
    activeQueryCode = new FormData(queryForm).get("query_code").toLowerCase().replaceAll(/\s/g, "");
    const registration = await api({ action: "query", query_code: activeQueryCode });
    document.querySelector("#serial-no").textContent = registration.serial_no;
    editForm.elements.full_name.value = registration.full_name;
    editForm.elements.district_id.innerHTML = districtOptions(registration.district_id);
    const values = new Map(registration.choices.map((choice) => [choice.activity_id, choice.attending]));
    document.querySelector("#edit-activities").innerHTML = activityFields(pageData.activities, values);
    editForm.hidden = false;
    editForm.querySelector("#cancel-button").hidden = registration.record_status !== "active";
    editForm.querySelector("#restore-button").hidden = registration.record_status !== "cancelled";
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
  setBusy(editForm, true);
  try {
    const data = new FormData(editForm);
    await api({
      action: "update",
      query_code: activeQueryCode,
      full_name: data.get("full_name"),
      district_id: Number(data.get("district_id")),
      choices: choicesFrom(editForm),
    });
    showMessage("登記資料已更新。重新查詢可確認最新內容。");
  } catch (error) {
    showMessage(error.message, true);
  } finally {
    setBusy(editForm, false);
  }
});

for (const [id, action] of [["#cancel-button", "cancel"], ["#restore-button", "restore"]]) {
  document.querySelector(id).addEventListener("click", async () => {
    setBusy(editForm, true);
    try {
      if (action === "restore") choicesFrom(editForm);
      await api({ action, query_code: activeQueryCode });
      showMessage(action === "cancel" ? "登記已取消。" : "登記已恢復。重新查詢可確認最新狀態。");
      editForm.hidden = true;
    } catch (error) {
      showMessage(error.message, true);
    } finally {
      setBusy(editForm, false);
    }
  });
}

loadPage();
