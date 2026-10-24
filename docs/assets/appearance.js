/* Cliphoard — the appearance choice. System, Light or Dark.
 *
 * WHY THIS IS A SEPARATE, CLASSIC SCRIPT IN <head>
 *
 * `site.js` is a deferred module: it runs after the document has been parsed, which is
 * after first paint. A visitor who chose Dark would therefore see the light page flash
 * before the attribute landed. This file is a blocking classic script placed before the
 * stylesheet so `data-theme` is on <html> before a single pixel is drawn. That is the
 * only reason it exists apart from `site.js`.
 *
 * WHAT IT IS NOT. It is not analytics and not an identifier. One key holds one of two
 * words. Nothing is sent anywhere, there is no clock, no random value, no cookie, and
 * no network call of any kind in this file.
 *
 * THE CSS DOES THE ACTUAL WORK. Each page's stylesheet declares its dark palette inside
 * `prefers-color-scheme: dark`, so System needs no JavaScript at all and an OS
 * appearance change retints the page with no reload. This file only ever sets an
 * OVERRIDE: `data-theme="dark"` or `data-theme="light"`. System removes the attribute
 * and the media query takes over again. That is why the page is still fully themed with
 * this file blocked, and why the control below is hidden until it is bound.
 *
 * STORAGE CAN BE A LANDMINE. Under a policy that denies site data, reading the
 * `window.localStorage` PROPERTY throws SecurityError — before `getItem` is ever
 * reached — and so can each individual read and write. All three are guarded
 * separately. A refusal to persist is NOT an error here: the choice still applies to
 * the page you are looking at, it simply will not survive the next load.
 */
(function () {
  "use strict";

  /* Namespaced to this app, so a shared origin cannot collide with it. */
  var KEY = "cliphoard.appearance";

  /* The only two values ever written. "system" is the ABSENCE of a stored value, which
   * is why choosing System deletes the key rather than storing a third word: there is
   * then nothing to migrate, and an empty store and a fresh visitor behave the same. */
  var EXPLICIT = ["light", "dark"];

  /* Read the page's own palette before paint() updates its metadata. The homepage and
   * legal pages share a preference, but can use different backgrounds. Keep the legacy
   * grounds as a fallback when metadata is absent or malformed. */
  var GROUND = { light: "#F5F5F5", dark: "#21252B" };
  var defaults = document.querySelectorAll('meta[name="theme-color"][data-scheme]');
  for (var d = 0; d < defaults.length; d++) {
    var scheme = defaults[d].getAttribute("data-scheme");
    var colour = defaults[d].getAttribute("content");
    if (EXPLICIT.indexOf(scheme) !== -1 && /^#[0-9a-f]{6}$/i.test(colour || "")) {
      GROUND[scheme] = colour;
    }
  }

  var root = document.documentElement;
  var current = "system";

  function darkQuery() {
    try {
      return window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;
    } catch (error) {
      return null;
    }
  }

  function systemIsDark() {
    var query = darkQuery();
    return Boolean(query && query.matches);
  }

  /** The stored choice, or "system" for anything this version does not recognise.
   *
   *  An unknown value is IGNORED rather than trusted: a future "sepia", a half-written
   *  value, or something another script put under this key all land on System, which is
   *  the one state that is always correct. */
  function stored() {
    var raw;
    try {
      raw = window.localStorage.getItem(KEY);
    } catch (error) {
      return "system";
    }
    return EXPLICIT.indexOf(raw) === -1 ? "system" : raw;
  }

  /** Persist, and report whether it worked. The caller does not act on `false`: a
   *  denied store still gets the theme it asked for, for this page. */
  function remember(choice) {
    try {
      if (choice === "system") window.localStorage.removeItem(KEY);
      else window.localStorage.setItem(KEY, choice);
      return true;
    } catch (error) {
      return false;
    }
  }

  /** Put `current` on the document and keep the browser-chrome colour in step.
   *
   *  `data-theme` is the override the stylesheet reads, and it is ABSENT for System so
   *  the media query decides. `data-appearance` and `data-resolved` are readbacks —
   *  they are what a QA pass, and `Tests/site/preview.html`, inspect to see which state
   *  the page is actually in. Nothing in the stylesheet keys off them. */
  function paint() {
    var resolved = current === "system" ? (systemIsDark() ? "dark" : "light") : current;

    if (current === "system") root.removeAttribute("data-theme");
    else root.setAttribute("data-theme", current);
    root.setAttribute("data-appearance", current);
    root.setAttribute("data-resolved", resolved);

    var metas = document.querySelectorAll('meta[name="theme-color"][data-scheme]');
    for (var i = 0; i < metas.length; i++) {
      // System leaves each entry describing its own scheme. An explicit choice makes
      // BOTH entries name the chosen ground, so whichever one the browser matches on
      // its own appearance is the colour that is really on screen.
      var scheme = current === "system" ? metas[i].getAttribute("data-scheme") : resolved;
      metas[i].setAttribute("content", GROUND[scheme] || GROUND.light);
    }
    return resolved;
  }

  current = stored();
  paint();

  /** Wire the control and reveal it. Idempotent: a second call is a no-op, so the
   *  readyState branch below cannot double-bind the change handler. */
  function bind() {
    var field = document.getElementById("appearance");
    if (!field || field.dataset.bound === "yes") return false;
    field.dataset.bound = "yes";
    field.value = current;

    field.addEventListener("change", function () {
      current = EXPLICIT.indexOf(field.value) === -1 ? "system" : field.value;
      remember(current);     // a refusal changes nothing about what happens next
      paint();
      field.value = current;
    });

    var group = document.getElementById("appearance-control");
    if (group) group.removeAttribute("hidden");
    return true;
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", bind, { once: true });
  } else {
    bind();
  }

  /* An OS appearance change. The palette swap is the stylesheet's job; this only keeps
   * the readbacks and the chrome colour honest, and it is deliberately a no-op while an
   * explicit choice is in force — an explicit choice outranks the OS. */
  var query = darkQuery();
  if (query) {
    var onSystemChange = function () { if (current === "system") paint(); };
    if (query.addEventListener) query.addEventListener("change", onSystemChange);
    else if (query.addListener) query.addListener(onSystemChange);
  }

  /* Another tab of the same site changed the choice. Re-READ rather than trusting
   * `event.newValue`, so a value this version does not recognise is rejected by exactly
   * the same rule as one found at startup. */
  window.addEventListener("storage", function (event) {
    if (event && event.key && event.key !== KEY) return;
    var next = stored();
    if (next === current) return;
    current = next;
    paint();
    var field = document.getElementById("appearance");
    if (field) field.value = current;
  });
})();
