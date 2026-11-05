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
  if (data.hosting) {
    const item = document.createElement("li");
    item.textContent = data.hosting;
    document.querySelector("#summary-choices").append(item);
  }
}
