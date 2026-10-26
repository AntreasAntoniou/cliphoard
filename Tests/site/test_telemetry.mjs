import test from "node:test";
import assert from "node:assert/strict";
import worker from "../../site/worker.mjs";
import { bootTelemetry, sourceGroup, SITE_EVENTS } from "../../docs/assets/telemetry.mjs";
import { recordMetric } from "../../telemetry/metrics.mjs";

const payload = { v: 1, event: "download_click", placement: "hero", source: "direct", mode: "qa" };
function fixture() {
  const points = [], limits = [];
  return { points, limits, env: {
    METRICS: { writeDataPoint: (value) => points.push(value) },
    METRICS_RATE_LIMITER: { limit: async (value) => { limits.push(value); return { success: true }; } },
    ASSETS: { fetch: async () => new Response("asset") },
  } };
}
function request(data = payload, options = {}) {
  return new Request("https://cliphoard.dev/__events", {
    method: "POST", headers: { Origin: "https://cliphoard.dev", "Content-Type": "application/json", "CF-Connecting-IP": "192.0.2.1", ...options.headers },
    body: JSON.stringify(data), ...options,
  });
}
test("accepted events contain only fixed fields; IP exists only as rate-limit hash", async () => {
  const f = fixture(), req = request(); Object.defineProperty(req, "cf", { value: { country: "GB" } });
  assert.equal((await worker.fetch(req, f.env)).status, 204);
  assert.deepEqual(f.points, [{ indexes: ["website:qa"], blobs: ["v1", "website", "qa", "download_click", "hero", "direct", "GB"], doubles: [1] }]);
  assert.match(f.limits[0].key, /^[a-f0-9]{64}$/);
  assert.ok(!JSON.stringify(f.points).includes(f.limits[0].key));
  assert.equal((await worker.fetch(new Request("https://cliphoard.dev/privacy.html"), f.env)).status, 200);
});
for (const [label, data] of [
  ["email", { ...payload, email: "private@example.invalid" }],
  ["raw URL", { ...payload, placement: "https://secret.invalid/?token=secret" }],
  ["unknown event", { ...payload, event: "clipboard_copy" }],
  ["inherited event", { ...payload, event: "constructor" }],
  ["wrong placement", { ...payload, placement: "monthly" }],
  ["invalid mode", { ...payload, mode: "test" }],
  ["unbounded referral", { ...payload, source: "secret search terms" }],
  ["unknown schema", { ...payload, v: 2 }], ["null", null],
]) test(`rejects ${label} without data writes`, async () => {
  const f = fixture(); assert.equal((await worker.fetch(request(data), f.env)).status, 400); assert.equal(f.points.length, 0);
});
test("wrong origin, queries, methods and non-JSON are rejected", async () => {
  for (const [req, code] of [
    [new Request("https://cliphoard.dev/__events"), 404],
    [new Request("https://cliphoard.dev/__events?token=secret", request()), 404],
    [new Request("https://other.invalid/__events", request()), 404],
    [request(payload, { headers: { Origin: "https://other.invalid" } }), 403],
    [request(payload, { headers: { Origin: "https://cliphoard.dev", "Content-Type": "text/plain" } }), 415],
  ]) { const f = fixture(); assert.equal((await worker.fetch(req, f.env)).status, code); assert.equal(f.points.length, 0); }
});
test("privacy signals and verified bots are ignored before rate limiting", async () => {
  for (const header of ["DNT", "Sec-GPC"]) {
    const f = fixture(), req = request(); req.headers.set(header, "1");
    assert.equal((await worker.fetch(req, f.env)).status, 204); assert.equal(f.limits.length, 0); assert.equal(f.points.length, 0);
  }
  const f = fixture(), req = request(); Object.defineProperty(req, "cf", { value: { botManagement: { verifiedBot: true } } });
  assert.equal((await worker.fetch(req, f.env)).status, 204); assert.equal(f.points.length, 0);
});
test("body limits and slow streams are bounded", async () => {
  const f = fixture();
  assert.equal((await worker.fetch(request({ ...payload, extra: "x".repeat(600) }), f.env)).status, 400);
  let cancelled = false;
  const req = new Request("https://cliphoard.dev/__events", { method: "POST", headers: request().headers,
    duplex: "half", body: new ReadableStream({ cancel() { cancelled = true; } }) });
  const start = Date.now();
  assert.equal((await worker.fetch(req, f.env)).status, 400);
  assert.ok(Date.now() - start < 2500); assert.equal(cancelled, true); assert.equal(f.points.length, 0);
});
test("rate limiting and unavailable analytics cannot disrupt assets", async () => {
  const f = fixture(); f.env.METRICS_RATE_LIMITER.limit = async () => ({ success: false });
  assert.equal((await worker.fetch(request(), f.env)).status, 429);
  f.env.METRICS_RATE_LIMITER.limit = async () => ({ success: true });
  f.env.METRICS.writeDataPoint = () => { throw new Error("outage"); };
  assert.equal((await worker.fetch(request(), f.env)).status, 503);
  assert.equal(await (await worker.fetch(new Request("https://cliphoard.dev/"), f.env)).text(), "asset");
});
function browser(overrides = {}) {
  const calls = [], listeners = {}, toggles = {};
  const detail = { open: false, dataset: { metricOpen: "pro_interest", placement: "purchase_details" }, addEventListener: (n, f) => { toggles[n] = f; } };
  const doc = { visibilityState: "visible", referrer: "https://www.google.com/search?q=private", querySelectorAll: () => [detail], addEventListener: (n, f) => { listeners[n] = f; } };
  const win = { location: { hostname: "cliphoard.dev", protocol: "https:", pathname: "/", search: "?token=private&metrics=qa" }, navigator: {}, fetch: async (...args) => calls.push(args), ...overrides };
  return { calls, listeners, toggles, detail, win, doc };
}
test("browser emits page and explicit intent only, deduplicates, and strips identity", () => {
  const f = browser(); bootTelemetry(f.win, f.doc);
  f.listeners.visibilitychange();
  f.detail.open = true; f.toggles.toggle(); f.toggles.toggle();
  const click = { button: 0, target: { closest: () => ({ dataset: { metric: "download_click", placement: "hero" } }) } };
  f.listeners.click(click); f.listeners.click(click);
  assert.equal(f.calls.length, 3);
  for (const [url, options] of f.calls) {
    assert.equal(url, "/__events"); assert.equal(options.credentials, "omit"); assert.equal(options.referrerPolicy, "no-referrer");
    const data = JSON.parse(options.body); assert.equal(data.source, "search"); assert.equal(data.mode, "qa");
    assert.deepEqual(Object.keys(data).sort(), ["event", "mode", "placement", "source", "v"]);
    assert.ok(!JSON.stringify(options).includes("private"));
  }
});
test("browser suppresses tracking preferences, previews and prerendering", () => {
  for (const overrides of [{ navigator: { doNotTrack: "1" } }, { navigator: { globalPrivacyControl: true } },
    { location: { hostname: "antreas.io", protocol: "https:", pathname: "/cliphoard/", search: "" } },
    { location: { hostname: "localhost", protocol: "http:", pathname: "/", search: "" } }]) {
    const f = browser(overrides); bootTelemetry(f.win, f.doc); assert.equal(f.calls.length, 0);
  }
  const f = browser(); f.doc.prerendering = true; bootTelemetry(f.win, f.doc); assert.equal(f.calls.length, 0);
});
test("hidden page waits for visibility; network failures do not retry", async () => {
  const f = browser(); f.doc.visibilityState = "hidden"; bootTelemetry(f.win, f.doc); assert.equal(f.calls.length, 0);
  f.doc.visibilityState = "visible"; f.listeners.visibilitychange(); assert.equal(f.calls.length, 1);
  const g = browser({ fetch: () => { throw new Error("offline"); } }); assert.doesNotThrow(() => bootTelemetry(g.win, g.doc));
});
test("source classification uses hostname boundaries and no query values", () => {
  assert.equal(sourceGroup("https://google.com.attacker.invalid/?q=x"), "other");
  assert.equal(sourceGroup("https://github.com/a?token=x"), "github");
  assert.equal(sourceGroup(""), "direct"); assert.equal(sourceGroup("garbage"), "other");
});
test("every website schema entry can be written; arbitrary commerce values cannot", () => {
  const f = fixture();
  for (const [event, placements] of Object.entries(SITE_EVENTS)) for (const placement of placements) {
    assert.equal(recordMetric(f.env, { surface: "website", mode: "qa", event, placement }), true);
  }
  assert.equal(recordMetric(f.env, { surface: "commerce", mode: "test", event: "secret", placement: "order" }), false);
  assert.equal(recordMetric(f.env, { surface: "commerce", mode: "test", event: "licence_issued", placement: "private@example.invalid" }), false);
});
