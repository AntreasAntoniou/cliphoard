// Serialized into a CSP-hashed inline script. Keep this function self-contained.
export function claimPageClient(runtime = globalThis) {
  const doc = runtime.document, appearance = doc.getElementById("appearance");
  const themes = ["system", "light", "dark"], themeKey = "cliphoard:purchase:appearance";
  try {
    const saved = runtime.sessionStorage.getItem(themeKey);
    if (themes.includes(saved)) appearance.value = saved;
  } catch {}
  function applyAppearance() {
    const value = themes.includes(appearance.value) ? appearance.value : "system";
    doc.documentElement.dataset.appearance = value;
    try { runtime.sessionStorage.setItem(themeKey, value); } catch {}
  }
  appearance.addEventListener("change", applyAppearance);
  applyAppearance();
  doc.getElementById("appearance-control").hidden = false;

  const copy = doc.getElementById("copy-key"), key = doc.getElementById("licence-key");
  if (copy && key) {
    const status = doc.getElementById("copy-status"), label = doc.getElementById("copy-label");
    copy.hidden = false;
    copy.addEventListener("click", async () => {
      if (copy.disabled) return;
      copy.disabled = true;
      try {
        await runtime.navigator.clipboard.writeText(key.value);
        label.textContent = "Copied";
        status.textContent = "Key copied. Now open Cliphoard Settings → Pro.";
      } catch {
        key.focus(); key.select();
        label.textContent = "Copy key";
        status.textContent = "Your key is selected. Press ⌘C on Mac or Ctrl+C to copy it.";
      } finally { copy.disabled = false; }
    });
  }
  const check = doc.getElementById("check-status");
  if (check) {
    check.hidden = false;
    check.addEventListener("click", () => {
      check.disabled = true; check.textContent = "Checking…";
      runtime.location.reload();
    });
  }
}
