/* Explicit ES module shared by the browser and Workers. No visitor identity or app activity. */
export const SITE_EVENTS = Object.freeze({
  page_view: ["home"],
  download_click: ["hero", "free_card"],
  pro_interest: ["navigation", "purchase_details"],
  feature_open: ["capture", "search", "appearance", "privacy", "move", "visual"],
  source_click: ["navigation", "body"],
  support_click: ["footer"],
  privacy_click: ["body", "footer"],
  sponsor_click: ["once", "monthly"],
  research_click: ["body"],
});
export const SOURCES = ["direct", "search", "github", "social", "internal", "other", "none"];
export function validSiteEvent(event, placement) {
  return Object.hasOwn(SITE_EVENTS, event) && SITE_EVENTS[event].includes(placement);
}
export function sourceGroup(referrer) {
  if (!referrer) return "direct";
  let host; try { host = new URL(referrer).hostname.toLowerCase(); } catch { return "other"; }
  if (["cliphoard.dev", "www.cliphoard.dev", "antreas.io"].includes(host)) return "internal";
  if (host === "github.com" || host.endsWith(".github.com")) return "github";
  if (["google.com", "google.co.uk", "bing.com", "duckduckgo.com", "search.brave.com"].some((h) => host === h || host.endsWith(`.${h}`))) return "search";
  if (["reddit.com", "x.com", "twitter.com", "t.co", "linkedin.com", "news.ycombinator.com"].some((h) => host === h || host.endsWith(`.${h}`))) return "social";
  return "other";
}
export function bootTelemetry(win = window, doc = document) {
  if (!['cliphoard.dev', 'www.cliphoard.dev'].includes(win.location.hostname) ||
      win.location.protocol !== "https:" || !["/", "/index.html"].includes(win.location.pathname) ||
      win.navigator.globalPrivacyControl === true || win.navigator.doNotTrack === "1" ||
      win.doNotTrack === "1" || doc.prerendering) return;
  const seen = new Set();
  const source = sourceGroup(doc.referrer);
  // Explicit QA mode is excluded from ordinary reports. No other query is read or sent.
  const mode = new URLSearchParams(win.location.search).get("metrics") === "qa" ? "qa" : "live";
  const emit = (event, placement) => {
    if (doc.visibilityState === "hidden" || !validSiteEvent(event, placement)) return;
    const key = `${event}:${placement}`;
    if (seen.has(key)) return;
    seen.add(key); // One intent per placement per page load, no persistent/session ID.
    try {
      win.fetch("/__events", { method: "POST", credentials: "omit", mode: "same-origin",
        cache: "no-store", referrerPolicy: "no-referrer", keepalive: true,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ v: 1, event, placement, source, mode }),
      }).catch(() => {}); // Analytics can never block a download or purchase.
    } catch { /* No retries, logging, cookies or storage. */ }
  };
  const page = () => emit("page_view", "home");
  page();
  doc.addEventListener("visibilitychange", page);
  doc.addEventListener("click", (event) => {
    if (event.button !== undefined && event.button !== 0) return;
    const target = event.target?.closest?.("[data-metric]");
    if (target) emit(target.dataset.metric, target.dataset.placement);
  });
  for (const detail of doc.querySelectorAll("details[data-metric-open]")) {
    detail.addEventListener("toggle", () => {
      if (detail.open) emit(detail.dataset.metricOpen, detail.dataset.placement);
    });
  }
}
