import { validSiteEvent, SOURCES } from "../docs/assets/telemetry.mjs";
import { recordMetric } from "../telemetry/metrics.mjs";

const ORIGINS = new Set(["https://cliphoard.dev", "https://www.cliphoard.dev"]);
const reply = (status) => new Response(null, { status, headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } });
async function body(request, milliseconds = 1000) {
  if (!request.body || Number(request.headers.get("Content-Length")) > 512) throw new Error("body");
  const reader = request.body.getReader();
  let timer, size = 0;
  const chunks = [];
  try {
    const read = async () => {
      for (;;) {
        const part = await reader.read();
        if (part.done) break;
        size += part.value.length;
        if (size > 512) throw new Error("body");
        chunks.push(part.value);
      }
      const bytes = new Uint8Array(size); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    };
    return await Promise.race([read(), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("timeout")), milliseconds); })]);
  } finally { clearTimeout(timer); void reader.cancel().catch(() => {}); }
}
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== "/__events") return env.ASSETS.fetch(request);
    if (!ORIGINS.has(url.origin) || request.method !== "POST" || url.search) return reply(404);
    if (request.headers.get("Origin") !== url.origin) return reply(403);
    if (request.headers.get("Sec-Fetch-Site") && request.headers.get("Sec-Fetch-Site") !== "same-origin") return reply(403);
    if (request.headers.get("DNT") === "1" || request.headers.get("Sec-GPC") === "1" || request.cf?.botManagement?.verifiedBot) return reply(204);
    if (!/^application\/json(?:\s*;|$)/i.test(request.headers.get("Content-Type") ?? "")) return reply(415);
    const ip = request.headers.get("CF-Connecting-IP");
    if (!ip || typeof env.METRICS_RATE_LIMITER?.limit !== "function") return reply(503);
    try {
      // IP is used only for transient edge throttling, never written to analytics.
      const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ip)));
      const key = Array.from(hash, (b) => b.toString(16).padStart(2, "0")).join("");
      if ((await env.METRICS_RATE_LIMITER.limit({ key }))?.success !== true) return reply(429);
    } catch { return reply(503); }
    let data;
    try { data = await body(request); } catch { return reply(400); }
    if (!data || Array.isArray(data) || Object.keys(data).sort().join() !== "event,mode,placement,source,v" ||
        data.v !== 1 || !["live", "qa"].includes(data.mode) || !SOURCES.includes(data.source) ||
        !validSiteEvent(data.event, data.placement)) return reply(400);
    const country = /^[A-Z]{2}$/.test(request.cf?.country ?? "") ? request.cf.country : "ZZ";
    return reply(recordMetric(env, { surface: "website", ...data, country }) ? 204 : 503);
  },
};
