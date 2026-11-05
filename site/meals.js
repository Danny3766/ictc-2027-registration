// 用餐身分（學生價）與報名對象, shared by the public page and the back office. The database applies the
// same rules (registration_meal_identity, registration_audience_valid); this only keeps the form in step.
const Meals = (() => {
  const identityLabels = { general: "一般", student: "學生" };
  const defaultAudienceNote = "本項優先開放有開家接待的聖徒報名";
  const revertedNote = "不符報名對象，已改為不參加。";
  // 是 and 家人已登記開家接待 both count as a hosting household.
  const hostingStatuses = ["hosting", "family_registered"];

  const hasStudentPrice = (activity) => activity.student_fee_amount != null;
  const eligible = (activity, hostingStatus) => activity.audience !== "hosting" || hostingStatuses.includes(hostingStatus);
  // Without an answered identity the general price applies, like the back-office estimate.
  const fee = (activity, identity) =>
    (identity === "student" && hasStudentPrice(activity) ? activity.student_fee_amount : activity.fee_amount) ?? 0;
  const needsIdentity = (activities, choices) => choices.some((choice) => choice.attending
    && activities.some((activity) => activity.id === choice.activity_id && hasStudentPrice(activity)));

  function feeText(activity) {
    const prices = [];
    if (activity.fee_amount != null) prices.push(`${hasStudentPrice(activity) ? "一般 " : ""}NT$${activity.fee_amount}／人`);
    if (hasStudentPrice(activity)) prices.push(`學生 NT$${activity.student_fee_amount}／人`);
    return prices.length ? `規劃費用：${prices.join("，")}` : "";
  }

  const radio = (container, activity, value) =>
    container.querySelector(`[name="activity_${activity.id}"][value="${value}"]`);
  const choiceOf = (container, activity) => {
    const value = container.querySelector(`[name="activity_${activity.id}"]:checked`)?.value;
    return value === undefined ? null : value === "true";
  };

  // Adds the audience notes and the identity question to activity fields just rendered in container;
  // each activity's wrapper carries data-activity="<id>". All text is set as text, never as markup.
  function render(container, activities, identity = null) {
    for (const activity of activities) {
      const wrapper = container.querySelector(`[data-activity="${activity.id}"]`);
      if (!wrapper || activity.audience !== "hosting") continue;
      const note = document.createElement("p");
      note.className = "hint audience-note";
      note.textContent = activity.audience_note || defaultAudienceNote;
      const reverted = document.createElement("p");
      reverted.className = "hint audience-reverted";
      reverted.textContent = revertedNote;
      reverted.hidden = true;
      wrapper.append(note, reverted);
    }
    if (!activities.some(hasStudentPrice)) return;
    const block = document.createElement("div");
    block.className = "activity meal-identity";
    block.hidden = true;
    const title = document.createElement("strong");
    title.textContent = "用餐身分";
    const options = document.createElement("div");
    options.className = "activity-options";
    options.setAttribute("role", "radiogroup");
    options.setAttribute("aria-label", "用餐身分");
    for (const [value, text] of Object.entries(identityLabels)) {
      const option = document.createElement("label");
      const input = document.createElement("input");
      input.type = "radio";
      input.name = "meal_identity";
      input.value = value;
      input.checked = value === identity;
      option.append(input, text);
      options.append(option);
    }
    const hint = document.createElement("p");
    hint.className = "hint";
    hint.textContent = "勾選的用餐有學生價，請選擇身分。";
    block.append(title, options, hint);
    container.append(block);
  }

  // Applies the rules for the current 開家接待 status (null = no answer): a restricted activity is
  // 不參加 and locked outside its audience, and the identity question shows, required, only while a
  // student-priced activity is attended. Hidden or locked fields are disabled, so the form's own checks
  // skip them; read choices with choices() below, since FormData leaves disabled fields out.
  // A 參加 reverted here comes back if the answer becomes eligible again on the same screen.
  function sync(container, activities, hostingStatus) {
    for (const activity of activities) {
      if (activity.audience !== "hosting") continue;
      const yes = radio(container, activity, "true");
      const no = radio(container, activity, "false");
      if (!yes || !no) continue;
      const allowed = eligible(activity, hostingStatus);
      const note = container.querySelector(`[data-activity="${activity.id}"] .audience-reverted`);
      if (!allowed && yes.checked) yes.dataset.reverted = "";
      if (allowed && yes.dataset.reverted !== undefined) {
        if (no.checked) yes.checked = true;
        delete yes.dataset.reverted;
      }
      if (note) note.hidden = yes.dataset.reverted === undefined;
      // A required question gets 不參加 so the form can be sent; an optional one left 未回覆 (an older
      // registration in the back office) stays unanswered, so saving it changes nothing.
      if (!allowed && (yes.checked || yes.required)) no.checked = true;
      yes.disabled = no.disabled = !allowed;
    }
    const block = container.querySelector(".meal-identity");
    if (!block) return;
    const needed = needsIdentity(activities, choices(container, activities));
    block.hidden = !needed;
    for (const input of block.querySelectorAll("input")) {
      input.disabled = !needed;
      input.required = needed;
    }
  }

  // Answered activities only; an unanswered one is left out.
  const choices = (container, activities) => activities
    .map((activity) => ({ activity_id: activity.id, attending: choiceOf(container, activity) }))
    .filter((choice) => choice.attending !== null);

  // null while the question is hidden: no student-priced activity is attended.
  const readIdentity = (container) =>
    container.querySelector('[name="meal_identity"]:checked:not(:disabled)')?.value ?? null;

  // A stored identity counts only while the choices still need one: after an admin removes a student
  // price or unpublishes the meal, the old value stays in the database until the next save.
  const identityFor = (activities, choices, identity) =>
    identity && needsIdentity(activities, choices) ? identity : null;

  // How many restricted activities sync() turned from 參加 into 不參加 in this container.
  const revertedCount = (container) => container.querySelectorAll("input[data-reverted]").length;

  return {
    identityLabels, hasStudentPrice, eligible, fee, needsIdentity, identityFor, feeText,
    render, sync, choices, readIdentity, revertedCount,
  };
})();
