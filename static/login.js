const form = document.querySelector("#login-form");
const username = document.querySelector("#username");
const password = document.querySelector("#password");
const submit = document.querySelector("#login-submit");
const error = document.querySelector("#login-error");

async function checkSession() {
  const response = await fetch("/api/session");
  const payload = await response.json().catch(() => ({}));
  if (payload.authenticated) {
    window.location.href = "/";
  }
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  error.classList.add("hidden");
  submit.disabled = true;
  submit.textContent = "登录中";
  try {
    const response = await fetch("/api/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        username: username.value.trim(),
        password: password.value,
      }),
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error(payload.error || "登录失败");
    }
    window.location.href = "/";
  } catch (loginError) {
    error.textContent = loginError.message;
    error.classList.remove("hidden");
    submit.disabled = false;
    submit.textContent = "登录";
  }
});

checkSession().catch(() => {});
