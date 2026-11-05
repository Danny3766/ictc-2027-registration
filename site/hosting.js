// 開家接待 fields, shared by the public page and the back office. The markup is static (no user
// data), so it is safe to set as innerHTML; answers are filled in through input values.
const Hosting = (() => {
  const statusLabels = { hosting: "開家接待", not_hosting: "這次不參加開家接待", family_registered: "家人已登記接待" };
  const guestLabels = { brother: "弟兄", sister: "姊妹", family: "家庭" };

  const markup = `
    <div class="hosting-options">
      ${Object.entries(statusLabels).map(([value, text]) =>
        `<label><input type="radio" name="hosting_status" value="${value}">${text}</label>`).join("")}
    </div>
    <div class="hosting-details" hidden>
      <fieldset class="hosting-guest">
        <legend>接待對象</legend>
        ${Object.entries(guestLabels).map(([value, text]) =>
          `<label><input type="radio" name="guest_type" value="${value}" required>${text}</label>`).join("")}
      </fieldset>
      <label class="hosting-family" hidden>家庭數<input name="family_count" type="number" min="1" max="99" step="1" inputmode="numeric" required></label>
      <label><span class="hosting-count-label">人數</span><input name="guest_count" type="number" min="1" max="99" step="1" inputmode="numeric" required></label>
      <label>備註（選填，200 字內）<textarea name="hosting_note" maxlength="200" rows="3"></textarea></label>
      <p class="hint">例如：家中有養貓、沒有電梯。請勿填寫地址或電話。</p>
    </div>`;

  function normalize(value) {
    if (!value?.status) return null;
    const hosting = value.status === "hosting";
    const family = hosting && value.guest_type === "family";
    const number = (item) => (item === null || item === undefined || item === "" ? null : Number(item));
    return {
      status: value.status,
      guest_type: hosting ? value.guest_type ?? null : null,
      guest_count: hosting ? number(value.guest_count) : null,
      family_count: family ? number(value.family_count) : null,
      note: hosting ? String(value.note ?? "").trim() || null : null,
    };
  }

  function summary(value) {
    const answer = normalize(value);
    if (!answer) return "未回覆";
    if (answer.status !== "hosting") return statusLabels[answer.status];
    const detail = answer.guest_type === "family"
      ? `家庭 ${answer.family_count} 組，共 ${answer.guest_count} 人`
      : `${guestLabels[answer.guest_type]} ${answer.guest_count} 人`;
    return `開家接待（${detail}）`;
  }

  // Shows only the fields the chosen answer needs; hidden fields are disabled so they neither
  // block the form's required checks nor get sent.
  function sync(container) {
    const field = (name) => container.querySelector(`[name="${name}"]`);
    const checked = (name) => container.querySelector(`[name="${name}"]:checked`)?.value;
    const details = container.querySelector(".hosting-details");
    const hosting = checked("hosting_status") === "hosting";
    details.hidden = !hosting;
    details.querySelectorAll("input, textarea").forEach((input) => { input.disabled = !hosting; });
    const family = hosting && checked("guest_type") === "family";
    container.querySelector(".hosting-family").hidden = !family;
    field("family_count").disabled = !family;
    container.querySelector(".hosting-count-label").textContent = family ? "總人數（所有家庭合計）" : "人數";
    const families = Number(field("family_count").value);
    const people = Number(field("guest_count").value);
    field("family_count").setCustomValidity(family && families && people && families > people ? "家庭數不能多於總人數" : "");
  }

  // required: a new answer must be given; an existing unanswered registration in the back office may stay 未回覆.
  function render(container, value = null, required = true) {
    container.innerHTML = markup;
    container.dataset.hosting = "";
    const answer = normalize(value);
    for (const radio of container.querySelectorAll('[name="hosting_status"]')) {
      radio.required = required;
      radio.checked = radio.value === answer?.status;
    }
    for (const radio of container.querySelectorAll('[name="guest_type"]')) radio.checked = radio.value === answer?.guest_type;
    container.querySelector('[name="family_count"]').value = answer?.family_count ?? "";
    container.querySelector('[name="guest_count"]').value = answer?.guest_count ?? "";
    container.querySelector('[name="hosting_note"]').value = answer?.note ?? "";
    sync(container);
  }

  function read(container) {
    const value = (name) => container.querySelector(`[name="${name}"]`)?.value;
    return normalize({
      status: container.querySelector('[name="hosting_status"]:checked')?.value,
      guest_type: container.querySelector('[name="guest_type"]:checked')?.value,
      guest_count: value("guest_count"),
      family_count: value("family_count"),
      note: value("hosting_note"),
    });
  }

  // Capture runs before the page's own listeners, so they already see the synced fields.
  // "input" also fires for radio buttons, so no "change" listener is needed.
  document.addEventListener("input", (event) => {
    const container = event.target.closest?.("[data-hosting]");
    if (container) sync(container);
  }, true);

  return { statusLabels, guestLabels, normalize, summary, render, read };
})();
