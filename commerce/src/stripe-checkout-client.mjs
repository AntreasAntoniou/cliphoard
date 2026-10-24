// Serialized into a CSP-hashed inline script. Keep this function self-contained.
export function checkoutPageClient(runtime = globalThis) {
  const doc = runtime.document, appearance = doc.getElementById("appearance");
  const themes = ["system", "light", "dark"], themeKey = "cliphoard:purchase:appearance";
  try { const saved = runtime.sessionStorage.getItem(themeKey); if (themes.includes(saved)) appearance.value = saved; } catch {}
  function applyAppearance() {
    const value = themes.includes(appearance.value) ? appearance.value : "system";
    doc.documentElement.dataset.appearance = value;
    try { runtime.sessionStorage.setItem(themeKey, value); } catch {}
  }
  appearance.addEventListener("change", applyAppearance); applyAppearance();
  const button = doc.getElementById("checkout"), status = doc.getElementById("checkout-status");
  if (!button) return;
  const storageKey = "cliphoard:purchase:attempt:v1", maximum = 3;
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
  let state = null, busy = false, blocked = "";
  function refreshAttempt() {
    try {
      const saved = runtime.sessionStorage.getItem(storageKey);
      if (saved === null && state) throw new Error("known attempt missing");
      if (saved !== null) {
        const current = JSON.parse(saved);
        if (!current || Object.keys(current).sort().join(",") !== "attempts,created,orderRef" || !uuid.test(current.orderRef) ||
            !Number.isSafeInteger(current.attempts) || current.attempts < 0 || current.attempts > maximum ||
            !Number.isSafeInteger(current.created) || current.created < 0 || current.created > runtime.Date.now() + 300000) throw new Error("invalid attempt");
        state = current;
      }
      blocked = state && runtime.Date.now() - state.created >= 25 * 60 * 1000
        ? "Your earlier checkout may still exist. Please contact support before starting another purchase." : "";
    } catch { blocked = "We cannot safely recover this checkout attempt. Please contact support before starting another purchase."; }
  }
  refreshAttempt();
  function idle(message = "") {
    busy = false;
    const exhausted = state?.attempts >= maximum;
    button.disabled = Boolean(blocked || exhausted);
    button.textContent = button.disabled ? "Checkout needs assistance" : "Continue to checkout";
    status.textContent = blocked || (exhausted ? "We could not safely finish this attempt. Please contact support before trying another purchase." : message);
  }
  idle(status.textContent);
  button.addEventListener("click", async () => {
    if (busy) return;
    // A restored document can have older memory than another page in this tab.
    // Re-read before each write so it never replaces a newer stored attempt.
    refreshAttempt(); idle(status.textContent);
    if (button.disabled || blocked) return;
    busy = true; button.disabled = true; button.textContent = "Opening checkout…"; status.textContent = "";
    let timer;
    try {
      if (!state) {
        const orderRef = runtime.crypto.randomUUID(); if (!uuid.test(orderRef)) throw new Error("invalid attempt");
        state = { orderRef, attempts: 0, created: runtime.Date.now() };
      }
      if (state.attempts >= maximum || runtime.Date.now() - state.created >= 25 * 60 * 1000) {
        blocked = "Your earlier checkout may still exist. Please contact support before starting another purchase."; throw new Error("blocked");
      }
      state.attempts++;
      try { runtime.sessionStorage.setItem(storageKey, JSON.stringify(state)); }
      catch { blocked = "Private session storage is unavailable. Please allow it before starting checkout, or contact support."; throw new Error("storage"); }
      const abort = new runtime.AbortController(); timer = runtime.setTimeout(() => abort.abort(), 30000);
      const response = await runtime.fetch("/checkout/stripe", {
        method: "POST", credentials: "omit", mode: "same-origin", cache: "no-store", redirect: "error",
        referrerPolicy: "no-referrer", headers: { "Content-Type": "application/json" }, signal: abort.signal,
        body: JSON.stringify({ orderRef: state.orderRef }),
      });
      if (!response.ok) throw new Error(response.status === 409 ? "not_open" : "unavailable");
      if (!/^application\/json(?:\s*;|$)/i.test(response.headers.get("Content-Type") ?? "")) throw new Error("invalid reply");
      const data = await response.json(), target = new URL(data.url);
      if (data.result !== "checkout_ready" || target.protocol !== "https:" || target.hostname !== "checkout.stripe.com" ||
          target.username || target.password || target.port) throw new Error("invalid destination");
      runtime.location.assign(target.href);
    } catch (error) {
      idle(error.message === "not_open"
        ? "This checkout is no longer open. If you paid, check your email for your Pro key. Contact support if you need help."
        : "Checkout did not open. You can retry this same attempt; we will not start a second order.");
    } finally { if (timer !== undefined) runtime.clearTimeout(timer); }
  });
  runtime.addEventListener("pageshow", (event) => {
    if (event.persisted) {
      refreshAttempt(); idle("You can continue your existing checkout below. If you already paid, check your email for your key.");
    }
  });
}
