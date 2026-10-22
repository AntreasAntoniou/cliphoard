/* Cliphoard — the page's deferred entry point.
 *
 * Two jobs, and deliberately nothing else: boot the funding figure, and mark which
 * section the reader is currently in. No analytics, no tracking, no remote script, no
 * font request, no cookie, no storage. The page is fully usable with this file blocked.
 *
 * The appearance choice is NOT here, and the split is not arbitrary: this is a module,
 * so it is deferred and runs after first paint, and a saved Dark choice applied from
 * here would flash the light page first. `assets/appearance.js` is a blocking classic
 * script in <head> for exactly that reason, and it is the only file on this site that
 * touches storage.
 */

import { bootFunding } from "./funding.js";

const funding = document.querySelector("[data-funding]");
if (funding) {
  // A relative URL, because this page is served from `/` on cliphoard.dev and from
  // `/cliphoard/` on antreas.io. An absolute `/data/...` would 404 on the second.
  bootFunding(funding, "data/net-sales.json");
}

/* Current-section marking. This is navigation, not decoration: the nav is the only
 * wayfinding on a long single page. `IntersectionObserver` rather than a scroll
 * handler so it costs nothing per frame. */
const links = Array.from(document.querySelectorAll(".topbar nav a[href^='#']"));
const sections = links
  .map((link) => document.getElementById(link.getAttribute("href").slice(1)))
  .filter(Boolean);

if (sections.length > 0 && "IntersectionObserver" in window) {
  const mark = (id) => {
    for (const link of links) {
      const current = link.getAttribute("href") === `#${id}`;
      if (current) link.setAttribute("aria-current", "true");
      else link.removeAttribute("aria-current");
    }
  };
  const observer = new IntersectionObserver((entries) => {
    const visible = entries
      .filter((entry) => entry.isIntersecting)
      .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top)[0];
    if (visible) mark(visible.target.id);
  }, { rootMargin: "-20% 0px -70% 0px" });
  for (const section of sections) observer.observe(section);
}
