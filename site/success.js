const raw = sessionStorage.getItem("registration_success");
const data = raw ? JSON.parse(raw) : null;
const backLink = document.querySelector("#back-link");
const confirmation = document.querySelector("#saved-confirmation");
let saved = false;

if (!data?.serial_no || !data?.query_code) {
  location.replace("./index.html");
} else {
  document.querySelector("#serial-no").textContent = data.serial_no;
  document.querySelector("#query-code").textContent = data.query_code;
}

document.querySelector("#copy-button").addEventListener("click", async () => {
  await navigator.clipboard.writeText(`流水號：${data.serial_no}\n查詢碼：${data.query_code}`);
  document.querySelector("#copy-button").textContent = "已複製";
});

document.querySelector("#print-button").addEventListener("click", () => window.print());

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
