/* Behaviour of docs/assets/appearance.js, by RUNNING IT.
 *
 * The real file is read off disk and executed with `window` and `document` supplied as
 * parameters, which shadow the globals — so this exercises the shipped source rather
 * than a transcription of it. There is no build step and no test double of the module:
 * the same bytes the browser gets are the bytes under test.
 *
 * The fake DOM is deliberately tiny. It implements only what the script actually
 * touches, so a script that starts reaching for something else fails loudly here
 * instead of passing against an accommodating mock.
 *
 * WHAT IS CHECKED, and why each one is a real failure mode rather than a restatement
 * of the code:
 *
 *   - a saved Dark choice is on <html> before DOMContentLoaded (the light-flash bug)
 *   - System sets NO override, because the stylesheet's media query owns that path
 *   - an unrecognised saved value is ignored rather than written onto the document
 *   - the `window.localStorage` GETTER throwing does not take the page down
 *   - a denied WRITE still changes the theme for the page you are on
 *   - choosing System deletes the key instead of storing a third word
 *   - an OS appearance change is answered in System and ignored under a choice
 *   - another tab's change is adopted if valid and rejected if not
 *   - binding twice does not install the change handler twice
 *   - the theme-colour metadata ends up agreeing with the chosen theme
 *   - nothing is published onto `window`
 *
 * Run:  node --test Tests/site/test_appearance.mjs
 */

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const APPEARANCE = path.join(HERE, "..", "..", "docs", "assets", "appearance.js");
const SOURCE = readFileSync(APPEARANCE, "utf8");

const KEY = "cliphoard.appearance";
const LIGHT_GROUND = "#F5F5F5";
const DARK_GROUND = "#21252B";

/* ── the smallest DOM the script can run against ──────────────────────────── */

function element(tag, attributes = {}) {
  return {
    tagName: tag,
    attributes: { ...attributes },
    dataset: {},
    value: "",
    handlers: new Map(),
    setAttribute(name, value) { this.attributes[name] = String(value); },
    getAttribute(name) {
      return Object.hasOwn(this.attributes, name) ? this.attributes[name] : null;
    },
    removeAttribute(name) { delete this.attributes[name]; },
    hasAttribute(name) { return Object.hasOwn(this.attributes, name); },
    addEventListener(type, listener) {
      if (!this.handlers.has(type)) this.handlers.set(type, []);
      this.handlers.get(type).push(listener);
    },
    fire(type, event) {
      for (const listener of [...(this.handlers.get(type) ?? [])]) listener(event);
    },
    listenerCount(type) { return (this.handlers.get(type) ?? []).length; },
  };
}

/**
 * One page, in one state.
 *
 * `storage` picks which failure to simulate: "ok", "getter-throws" (a policy that
 * denies site data, where reading the PROPERTY raises), "read-throws" or
 * "write-throws". `ready` is `document.readyState` at the moment the script runs.
 */
function page({ saved, storage = "ok", systemDark = false, ready = "loading" } = {}) {
  const root = element("html");
  const select = element("select");
  const group = element("div", { hidden: "" });
  const metas = [
    element("meta", { name: "theme-color", "data-scheme": "light", content: LIGHT_GROUND }),
    element("meta", { name: "theme-color", "data-scheme": "dark", content: DARK_GROUND }),
  ];

  const store = new Map();
  if (saved !== undefined) store.set(KEY, saved);
  const writes = [];

  const localStorage = {
    getItem(key) {
      if (storage === "read-throws") throw new Error("SecurityError");
      return store.has(key) ? store.get(key) : null;
    },
    setItem(key, value) {
      if (storage === "write-throws") throw new Error("QuotaExceededError");
      writes.push(["set", key, value]);
      store.set(key, value);
    },
    removeItem(key) {
      if (storage === "write-throws") throw new Error("QuotaExceededError");
      writes.push(["remove", key]);
      store.delete(key);
    },
  };

  const media = element("mql");
  media.matches = systemDark;
  const asked = [];

  const document_ = element("#document");
  document_.documentElement = root;
  document_.readyState = ready;
  document_.getElementById = (id) =>
    id === "appearance" ? select : id === "appearance-control" ? group : null;
  document_.querySelectorAll = (selector) =>
    selector.includes("theme-color") ? metas : [];

  const window_ = element("#window");
  window_.matchMedia = (query) => { asked.push(query); return media; };
  if (storage === "getter-throws") {
    Object.defineProperty(window_, "localStorage", {
      get() { throw new Error("SecurityError: storage is denied by policy"); },
      configurable: true,
    });
  } else {
    window_.localStorage = localStorage;
  }

  const before = new Set(Object.keys(window_));

  return {
    root, select, group, metas, store, writes, media, asked, before,
    document: document_, window: window_,
    /** Execute the shipped file. `window` and `document` shadow the globals. */
    boot() {
      new Function("window", "document", SOURCE)(this.window, this.document);
      return this;
    },
    /** The DOMContentLoaded the browser would deliver. */
    domReady() { this.document.fire("DOMContentLoaded"); return this; },
    theme() { return this.root.getAttribute("data-theme"); },
    choice() { return this.root.getAttribute("data-appearance"); },
    resolved() { return this.root.getAttribute("data-resolved"); },
    chrome() { return this.metas.map((meta) => meta.getAttribute("content")); },
  };
}

/* ── the flash this file exists to prevent ────────────────────────────────── */

test("a saved dark choice is on the document before the DOM is even ready", () => {
  const p = page({ saved: "dark" }).boot();
  // NOT after domReady(): if the override only landed then, the browser would already
  // have painted the light page once.
  assert.equal(p.theme(), "dark");
  assert.equal(p.choice(), "dark");
  assert.equal(p.resolved(), "dark");
});

test("a saved light choice holds even though the system is dark", () => {
  const p = page({ saved: "light", systemDark: true }).boot();
  assert.equal(p.theme(), "light");
  assert.equal(p.resolved(), "light");
});

/* ── System is the stylesheet's job ───────────────────────────────────────── */

test("System sets no override, so the media query is left to decide", () => {
  for (const systemDark of [false, true]) {
    const p = page({ systemDark }).boot();
    assert.equal(p.theme(), null,
      "an override under System would freeze the page at one theme");
    assert.equal(p.choice(), "system");
    assert.equal(p.resolved(), systemDark ? "dark" : "light");
  }
});

test("System does not write anything to storage", () => {
  const p = page().boot().domReady();
  assert.deepEqual(p.writes, []);
  assert.equal(p.store.has(KEY), false);
});

/* ── values that are not ours ─────────────────────────────────────────────── */

for (const rubbish of ["midnight", "DARK", "", "system", "true", "null", "sepia"]) {
  test(`a saved ${JSON.stringify(rubbish)} is ignored rather than applied`, () => {
    const p = page({ saved: rubbish }).boot().domReady();
    assert.equal(p.theme(), null, `${rubbish} reached the document`);
    assert.equal(p.choice(), "system");
    assert.equal(p.select.value, "system", "the control claims a state it is not in");
  });
}

/* ── storage that refuses ─────────────────────────────────────────────────── */

test("the localStorage getter throwing does not stop the page booting", () => {
  // The documented shape of a deny-storage policy: reading the PROPERTY raises
  // SecurityError, before getItem is ever reached.
  const p = page({ storage: "getter-throws", systemDark: true });
  assert.doesNotThrow(() => p.boot().domReady());
  assert.equal(p.choice(), "system");
  assert.equal(p.resolved(), "dark", "it should still follow the OS");
  assert.equal(p.group.hasAttribute("hidden"), false,
    "the control is still operable; only persistence is gone");
});

test("a read that throws falls back to System rather than to a guess", () => {
  const p = page({ storage: "read-throws" });
  assert.doesNotThrow(() => p.boot().domReady());
  assert.equal(p.theme(), null);
  assert.equal(p.choice(), "system");
});

test("choosing Dark with persistence denied still changes THIS page", () => {
  const p = page({ storage: "write-throws" }).boot().domReady();
  p.select.value = "dark";
  assert.doesNotThrow(() => p.select.fire("change"));
  assert.equal(p.theme(), "dark", "a refusal to persist swallowed the choice");
  assert.equal(p.resolved(), "dark");
  assert.deepEqual(p.chrome(), [DARK_GROUND, DARK_GROUND]);
});

/* ── choosing, and unchoosing ─────────────────────────────────────────────── */

test("choosing Dark persists exactly one key with exactly one word", () => {
  const p = page().boot().domReady();
  p.select.value = "dark";
  p.select.fire("change");
  assert.deepEqual(p.writes, [["set", KEY, "dark"]]);
  assert.deepEqual([...p.store.entries()], [[KEY, "dark"]]);
});

test("choosing System deletes the override instead of storing a third word", () => {
  const p = page({ saved: "dark" }).boot().domReady();
  assert.equal(p.select.value, "dark", "the control did not reflect the saved state");
  p.select.value = "system";
  p.select.fire("change");
  assert.equal(p.theme(), null);
  assert.deepEqual(p.writes, [["remove", KEY]]);
  assert.equal(p.store.has(KEY), false);
});

test("a value the control should not be able to hold lands on System", () => {
  const p = page().boot().domReady();
  p.select.value = "neon";          // e.g. an extension editing the options
  p.select.fire("change");
  assert.equal(p.theme(), null);
  assert.equal(p.select.value, "system", "the control was left showing a dead value");
});

/* ── the control appears only once it works ───────────────────────────────── */

test("the control stays hidden until it has been bound", () => {
  const p = page().boot();
  assert.equal(p.group.hasAttribute("hidden"), true,
    "an unbound control is offered and does nothing");
  p.domReady();
  assert.equal(p.group.hasAttribute("hidden"), false);
});

test("a document that is already parsed is bound immediately", () => {
  const p = page({ ready: "complete" }).boot();
  assert.equal(p.group.hasAttribute("hidden"), false);
  assert.equal(p.select.listenerCount("change"), 1);
});

test("binding twice does not install the change handler twice", () => {
  // The fake does not implement `{ once: true }` ON PURPOSE, so what is under test is
  // the script's own `dataset.bound` guard rather than the browser's.
  const p = page().boot().domReady().domReady();
  assert.equal(p.select.listenerCount("change"), 1);
  p.select.value = "dark";
  p.select.fire("change");
  assert.deepEqual(p.writes, [["set", KEY, "dark"]], "the handler ran twice");
});

/* ── the OS changing underneath ───────────────────────────────────────────── */

test("an OS appearance change is answered while the choice is System", () => {
  const p = page({ systemDark: false }).boot().domReady();
  assert.equal(p.resolved(), "light");
  p.media.matches = true;
  p.media.fire("change");
  assert.equal(p.resolved(), "dark");
  assert.equal(p.theme(), null, "answering the OS must not pin an override");
  assert.deepEqual(p.chrome(), [LIGHT_GROUND, DARK_GROUND],
    "under System each metadata entry keeps describing its own scheme");
});

test("an OS appearance change cannot override an explicit choice", () => {
  const p = page({ saved: "light" }).boot().domReady();
  p.media.matches = true;
  p.media.fire("change");
  assert.equal(p.theme(), "light", "the OS overrode a choice the visitor made");
  assert.equal(p.resolved(), "light");
  assert.equal(p.select.value, "light");
});

test("only the one media query is ever asked about", () => {
  const p = page().boot();
  assert.deepEqual([...new Set(p.asked)], ["(prefers-color-scheme: dark)"]);
});

/* ── another tab of the same site ─────────────────────────────────────────── */

test("a valid choice made in another tab is adopted here", () => {
  const p = page().boot().domReady();
  p.store.set(KEY, "dark");         // the other tab wrote it before the event fired
  p.window.fire("storage", { key: KEY, newValue: "dark" });
  assert.equal(p.theme(), "dark");
  assert.equal(p.select.value, "dark", "the control is out of step with the page");
});

test("another tab clearing the key returns this one to System", () => {
  const p = page({ saved: "dark" }).boot().domReady();
  p.store.delete(KEY);
  p.window.fire("storage", { key: null, newValue: null });   // a storage.clear()
  assert.equal(p.theme(), null);
  assert.equal(p.select.value, "system");
});

test("rubbish from another tab is rejected by the same rule as rubbish on disk", () => {
  const p = page({ saved: "dark" }).boot().domReady();
  p.store.set(KEY, "midnight");
  p.window.fire("storage", { key: KEY, newValue: "midnight" });
  assert.equal(p.theme(), null, "an unknown value was trusted because a tab sent it");
  assert.equal(p.choice(), "system");
});

test("an unrelated key changing is left alone", () => {
  const p = page({ saved: "dark" }).boot().domReady();
  p.store.set("something.else", "whatever");
  p.window.fire("storage", { key: "something.else", newValue: "whatever" });
  assert.equal(p.theme(), "dark", "an unrelated key disturbed the theme");
});

/* ── metadata, and what is NOT left behind ────────────────────────────────── */

test("an explicit choice makes both metadata entries name the chosen ground", () => {
  // Whichever entry the browser matches on its own appearance is then the colour that
  // is really on screen, which is the only way to make an explicit choice and a
  // media-scoped <meta> agree.
  const chosenDark = page({ saved: "dark", systemDark: false }).boot();
  assert.deepEqual(chosenDark.chrome(), [DARK_GROUND, DARK_GROUND]);
  const chosenLight = page({ saved: "light", systemDark: true }).boot();
  assert.deepEqual(chosenLight.chrome(), [LIGHT_GROUND, LIGHT_GROUND]);
});

test("nothing is published onto window", () => {
  const p = page().boot().domReady();
  const added = Object.keys(p.window).filter((name) => !p.before.has(name));
  assert.deepEqual(added, [], `the script leaked ${added.join(", ")}`);
});

test("the file is a self-contained classic script with no imports", () => {
  // It has to be: a module would be deferred, which is the whole bug it prevents.
  assert.equal(/^\s*(import|export)\s/m.test(SOURCE), false);
  assert.match(SOURCE, /^\(function \(\) \{$/m, "it is not wrapped in an IIFE");
  for (const forbidden of ["fetch(", "XMLHttpRequest", "document.cookie",
                           "sendBeacon", "Math.random", "Date.now", "sessionStorage"]) {
    assert.equal(SOURCE.includes(forbidden), false, `it reaches for ${forbidden}`);
  }
});
