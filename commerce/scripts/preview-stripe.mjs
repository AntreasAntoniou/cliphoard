// Local-only visual fixture. Never deploy; never connect to Stripe or email.
import { createServer } from "node:http";
import { fixture, wireOrders } from "../test/stripe-fixtures.mjs";
import { createStripeWorker } from "../src/stripe-worker.mjs";
if (Number(process.versions.node.split(".")[0]) < 24) throw new Error("Use the verified Node 24 runtime");
globalThis.fetch = async () => { throw new Error("Preview network is disabled"); };
const f = await fixture(); wireOrders(f);
f.env.STRIPE_API_KEY = "rk_test_synthetic0123456789012345";
f.env.EMAIL.send = async () => { throw new Error("Preview email is disabled"); };
const worker = createStripeWorker(() => { throw new Error("Preview Stripe is disabled"); });
const server = createServer(async (request, reply) => {
  try {
    const path = new URL(request.url, "http://127.0.0.1").pathname;
    if (request.method !== "GET") {
      reply.writeHead(503, { "Content-Type": "application/json", "Cache-Control": "no-store" });
      reply.end(JSON.stringify({ result: "local_preview_only" })); return;
    }
    if (!["/", "/ready", "/cancelled"].includes(path)) { reply.writeHead(404); reply.end(); return; }
    const env = { ...f.env, CHECKOUT_ENABLED: path === "/" ? "false" : "true" };
    const url = env.PUBLIC_ORIGIN + (path === "/cancelled" ? "/?cancelled=1" : "/");
    const response = await worker.fetch(new Request(url), env);
    reply.writeHead(response.status, Object.fromEntries(response.headers)); reply.end(await response.text());
  } catch { reply.writeHead(503); reply.end("Local preview unavailable"); }
});
server.listen(Number(process.env.CLIPHOARD_PREVIEW_PORT ?? 0), "127.0.0.1", () => {
  const base = `http://127.0.0.1:${server.address().port}`;
  console.log(JSON.stringify({ unavailable: base + "/", syntheticReady: base + "/ready", cancelled: base + "/cancelled", note: "Synthetic visual fixture. Every POST is rejected; no provider or email calls." }));
});
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => server.close(() => process.exit(0)));
