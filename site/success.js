let data = null;
try { data = JSON.parse(sessionStorage.getItem("registration_success") ?? "null"); } catch { data = null; }

if (window.APP_CONFIG?.environment === "test") document.querySelector("#test-banner").hidden = false;

if (!data?.full_name) {
  location.replace("./index.html");
} else {
  document.querySelector("#summary-identity").textContent = `${data.full_name}｜${data.district}`;
  document.querySelector("#summary-choices").replaceChildren(...data.choices.map((choice) => {
    const item = document.createElement("li");
    item.textContent = `${choice.title}：${choice.attending ? "參加" : "不參加"}`;
    return item;
  }));
  // Older saved summaries have no hosting line; the registration page only adds one while hosting is open.
  for (const line of [data.meal_identity, data.hosting].filter(Boolean)) {
    const item = document.createElement("li");
    item.textContent = line;
    document.querySelector("#summary-choices").append(item);
  }
}
