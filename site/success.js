const raw = sessionStorage.getItem("registration_success");
const data = raw ? JSON.parse(raw) : null;
const backLink = document.querySelector("#back-link");
const confirmation = document.querySelector("#saved-confirmation");
let saved = false;

if (window.APP_CONFIG?.environment === "test") document.querySelector("#test-banner").hidden = false;

if (!data?.query_code) {
  location.replace("./index.html");
} else {
  document.querySelector("#query-code").textContent = data.query_code;
}

document.querySelector("#copy-button").addEventListener("click", async () => {
  const copyMessage = document.querySelector("#copy-message");
  try {
    await navigator.clipboard.writeText(data.query_code);
    document.querySelector("#copy-button").textContent = "已複製查詢碼";
    copyMessage.textContent = "請貼到您會保存的地方，再勾選下方確認。";
  } catch {
    copyMessage.textContent = "無法自動複製，請手動選取上方查詢碼並保存。";
  }
  copyMessage.hidden = false;
});

confirmation.addEventListener("change", () => {
  saved = confirmation.checked;
  backLink.setAttribute("aria-disabled", String(!saved));
  if (saved) sessionStorage.removeItem("registration_success");
});

window.addEventListener("beforeunload", (event) => {
  if (!saved) {
    event.preventDefault();
    event.returnValue = "";
  }
});
