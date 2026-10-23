import test from "node:test";
import assert from "node:assert/strict";
import { Miniflare, Log, LogLevel } from "miniflare";
import { fileURLToPath } from "node:url";
import { environment, order, request, receipt, licenseFrom } from "./fixtures.mjs";

test("Cloudflare workerd: Ed25519/HMAC, actual KV, receipt, replay and refund", { timeout: 30000 }, async () => {
  const env = await environment(), p = order();
  const { RECEIPTS: unusedKV, ...bindings } = env;
  const mf = new Miniflare({
    modules: true, scriptPath: fileURLToPath(new URL("../src/worker.mjs", import.meta.url)),
    compatibilityDate: "2026-07-01", bindings, kvNamespaces: ["RECEIPTS"],
    host: "127.0.0.1", port: 0, log: new Log(LogLevel.NONE),
  });
  const dispatch = async (req) => mf.dispatchFetch(req.url, {
    method: req.method, headers: Object.fromEntries(req.headers),
    ...(req.method === "POST" ? { body: await req.text() } : {}),
  });
  try {
    assert.equal((await dispatch(request(env, p, { signature: "f".repeat(64) }))).status, 401);
    assert.equal((await dispatch(request(env, p))).status, 200);
    const r = await dispatch(receipt(env, p));
    assert.equal(r.status, 200);
    const first = licenseFrom(await r.text());
    assert.ok(first, "real workerd emits the offline key format");
    assert.equal((await dispatch(request(env, p))).status, 200);
    const second = licenseFrom(await (await dispatch(receipt(env, p))).text());
    assert.ok(first === second, "replay keeps same key");
    const kv = await mf.getKVNamespace("RECEIPTS");
    assert.equal((await kv.list()).keys.length, 1);
    p.meta.event_name = "order_refunded"; p.data.attributes.refunded = true;
    assert.equal((await dispatch(request(env, p))).status, 200);
    assert.equal((await dispatch(receipt(env, p))).status, 410);
  } finally { await mf.dispose(); }
});

test("independent workerd instances with empty KV issue the same key", { timeout: 30000 }, async () => {
  const env = await environment(), p = order();
  const { RECEIPTS: unusedKV, ...bindings } = env;
  let previous;
  // Sequential instances avoid resource contention; each owns fresh in-memory KV.
  for (let run = 0; run < 2; run++) {
    const mf = new Miniflare({
      modules: true, scriptPath: fileURLToPath(new URL("../src/worker.mjs", import.meta.url)),
      compatibilityDate: "2026-07-01", bindings, kvNamespaces: ["RECEIPTS"],
      host: "127.0.0.1", port: 0, log: new Log(LogLevel.NONE),
    });
    try {
      const kv = await mf.getKVNamespace("RECEIPTS");
      assert.equal((await kv.list()).keys.length, 0, "independent storage starts empty");
      const req = request(env, p);
      const result = await mf.dispatchFetch(req.url, {
        method: "POST", headers: Object.fromEntries(req.headers), body: await req.text(),
      });
      assert.equal(result.status, 200);
      assert.equal((await result.json()).result, "issued");
      const delivered = await mf.dispatchFetch(receipt(env, p).url);
      assert.equal(delivered.status, 200);
      const current = licenseFrom(await delivered.text());
      assert.ok(current, "runtime independently signs a key");
      if (previous !== undefined) assert.ok(previous === current, "independent signatures must be byte-identical");
      previous = current;
    } finally { await mf.dispose(); }
  }
});
