#!/usr/bin/env python3
"""Structure, resolution, accessibility and truth-in-advertising checks for docs/.

Five kinds of assertion, kept separate on purpose:

  * RESOLUTION — every relative URL resolves, under BOTH roots the site is served from
    (`/` on cliphoard.dev and `/cliphoard/` on antreas.io). Not hypothetical: STATUS.md
    records cliphoard.dev as not resolving, so the subpath is the live one today.
  * ACCESSIBILITY — one h1, no skipped heading levels, a working skip link, alt text,
    labelled landmarks, scoped table headers, a 320px breakpoint.
  * CLAIMS — what the page is allowed and not allowed to say, measured against the code
    where there is code behind it. This page makes claims about money and about an
    unreleased build, so the negative assertions matter as much as the positive ones.
  * MOBILE — the first viewport on a phone, and the ruler's endpoints.
  * HARNESS — that `Tests/site/preview.html` is local-only, unmistakably synthetic,
    renders at the exact widths it offers, and drives the real module.

Run:  python3 -m unittest discover -s Tests/site -p 'test_*.py'
"""

import json
import re
import unittest
from html.parser import HTMLParser
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
DOCS = REPO / "docs"
INDEX = DOCS / "index.html"
HARNESS = REPO / "Tests" / "site" / "preview.html"
NARROW_MEDIA = r"@media \(max-width:30rem\)\s*\{(.*?)\n\}"


class Collector(HTMLParser):
    """A single pass gathering everything the assertions below need."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.tags: list[tuple[str, dict]] = []
        self.ids: list[str] = []
        self.headings: list[tuple[int, str]] = []
        self._heading: int | None = None
        self.heading_text = ""

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        self.tags.append((tag, a))
        if "id" in a:
            self.ids.append(a["id"])
        if tag in ("h1", "h2", "h3", "h4", "h5", "h6"):
            self._heading = int(tag[1])
            self.heading_text = ""

    def handle_endtag(self, tag):
        if tag in ("h1", "h2", "h3", "h4", "h5", "h6") and self._heading is not None:
            self.headings.append((self._heading, self.heading_text.strip()))
            self._heading = None

    def handle_data(self, data):
        if self._heading is not None:
            self.heading_text += data

    def of(self, tag):
        return [a for t, a in self.tags if t == tag]


def parse(path=INDEX) -> Collector:
    c = Collector()
    c.feed(path.read_text(encoding="utf-8"))
    return c


def flat(path: Path) -> str:
    """Lowercased, emphasis stripped, whitespace collapsed.

    IDENTICAL to the normalisation in `Tests/CliphoardTests/DocsLaunchClaimTests.swift`,
    deliberately, because the claim mirror below has to fail for the same reasons that
    suite would — and that suite needs a full app build, which a change to one HTML file
    should not require.
    """
    s = path.read_text(encoding="utf-8").lower()
    for tag in ("<b>", "</b>", "<i>", "</i>", "**", "*"):
        s = s.replace(tag, "")
    return " ".join(s.split())


def section(name: str) -> str:
    raw = INDEX.read_text(encoding="utf-8")
    match = re.search(r'<section id="%s".*?</section>' % name, raw, re.S)
    assert match, "no #%s section" % name
    return match.group(0)


def hero() -> str:
    raw = INDEX.read_text(encoding="utf-8")
    return re.search(r'<header class="hero.*?</header>', raw, re.S).group(0)


def strip_comments(source: str) -> str:
    """Comment-free source, for both JS and Python.

    Prose ABOUT a token is not a use of it. Both `funding.js` and the publisher explain
    at length why `not_live` was removed, and a scan over the raw text would match those
    explanations — the trap `ForgetOrderingTests` documents in this repository.
    """
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    source = re.sub(r'"""[\s\S]*?"""', "", source)
    return "\n".join(line for line in source.split("\n")
                     if not line.lstrip().startswith(("//", "#")))


def visible(html: str) -> str:
    """Rendered text only, lowercased — so an assertion cannot be satisfied by a comment
    or an attribute the reader never sees."""
    body = re.sub(r"<!--.*?-->", " ", html, flags=re.S)
    body = re.sub(r"<[^>]+>", " ", body)
    return " ".join(body.lower().split())


def css() -> str:
    return (DOCS / "assets" / "site.css").read_text(encoding="utf-8")


def narrow_block() -> str:
    match = re.search(NARROW_MEDIA, css(), re.S)
    assert match, "there is no 320px-class breakpoint"
    return match.group(1)


class Resolution(unittest.TestCase):

    def setUp(self):
        self.page = parse()

    def urls(self):
        for tag, a in self.page.tags:
            if tag == "img" and "src" in a:
                yield "img src", a["src"]
            elif tag == "script" and "src" in a:
                yield "script src", a["src"]
            elif tag == "link" and "href" in a and a.get("rel") != "canonical":
                yield "link %s" % a.get("rel"), a["href"]
            elif tag == "a" and "href" in a:
                yield "a href", a["href"]

    def test_every_relative_url_resolves_to_a_file_that_exists(self):
        for where, url in self.urls():
            if url.startswith(("http://", "https://", "#", "mailto:")):
                continue
            target = (DOCS / url.split("#")[0].split("?")[0]).resolve()
            self.assertTrue(target.is_file(), "%s=%s does not exist" % (where, url))

    def test_no_url_is_root_absolute(self):
        for where, url in self.urls():
            self.assertFalse(url.startswith("/"),
                             "%s=%s is root-absolute and 404s on the subpath" % (where, url))

    def test_the_page_works_identically_under_both_roots(self):
        import posixpath
        for root in ("/", "/cliphoard/"):
            for where, url in self.urls():
                if url.startswith(("http://", "https://", "#", "mailto:")):
                    continue
                served = posixpath.normpath(posixpath.join(root, url.split("#")[0]))
                self.assertTrue(served.startswith(root.rstrip("/") or "/"),
                                "%s=%s escapes %s" % (where, url, root))

    def test_every_in_page_anchor_has_a_target(self):
        for where, url in self.urls():
            if url.startswith("#"):
                self.assertIn(url[1:], self.page.ids, "%s=%s points nowhere" % (where, url))

    def test_no_id_is_duplicated(self):
        duplicates = {i for i in self.page.ids if self.page.ids.count(i) > 1}
        self.assertEqual(duplicates, set())

    def test_the_pro_anchor_exists_because_the_app_binary_depends_on_it(self):
        # `Licence.buyURL` is what the in-app "Get Pro" button opens. If this id
        # disappears, a paying-curious user lands at the top of the page instead of at
        # the section that explains the situation.
        licence = (REPO / "Sources/Cliphoard/Support/Licence.swift").read_text(encoding="utf-8")
        match = re.search(r'buyURL\s*=\s*URL\(string:\s*"([^"]+)"', licence)
        self.assertIsNotNone(match, "Licence.buyURL is no longer a literal URL")
        fragment = match.group(1).split("#")
        self.assertEqual(len(fragment), 2, "Licence.buyURL has no fragment")
        self.assertIn(fragment[1], self.page.ids,
                      "Licence.buyURL points at a fragment this page lacks")

    def test_the_canonical_url_agrees_with_the_cname(self):
        host = (DOCS / "CNAME").read_text(encoding="utf-8").strip()
        canonical = [a["href"] for a in self.page.of("link") if a.get("rel") == "canonical"]
        self.assertEqual(canonical, ["https://%s/" % host])

    def test_the_funding_data_file_is_reachable_from_the_page(self):
        site_js = (DOCS / "assets" / "site.js").read_text(encoding="utf-8")
        match = re.search(r'bootFunding\([^,]+,\s*"([^"]+)"', site_js)
        self.assertIsNotNone(match)
        self.assertFalse(match.group(1).startswith("/"))
        self.assertTrue((DOCS / match.group(1)).is_file())


class NoRemoteDependencies(unittest.TestCase):

    def test_no_script_or_stylesheet_is_loaded_from_another_origin(self):
        for tag, a in parse().tags:
            if tag == "script" and "src" in a:
                self.assertFalse(a["src"].startswith(("http", "//")), "remote script")
            if tag == "link" and a.get("rel") in ("stylesheet", "preload", "modulepreload"):
                self.assertFalse(a["href"].startswith(("http", "//")), "remote stylesheet")

    def test_no_webfont_is_requested(self):
        sheet = css()
        self.assertNotIn("@font-face", sheet)
        self.assertNotIn("@import", sheet)
        for host in ("fonts.googleapis", "fonts.gstatic", "typekit", "cdn."):
            self.assertNotIn(host, sheet)

    def test_there_is_no_tracking_or_embedding_of_any_kind(self):
        raw = INDEX.read_text(encoding="utf-8").lower()
        for needle in ("<iframe", "google-analytics", "googletagmanager", "gtag(",
                       "plausible", "fathom", "hotjar", "<noscript><img",
                       "tracking pixel", "1x1.", "localstorage", "document.cookie",
                       "navigator.sendbeacon", "new image("):
            self.assertNotIn(needle, raw, "%s has no business being here" % needle)

    def test_no_inline_script_runs_outside_the_one_module(self):
        scripts = parse().of("script")
        self.assertEqual(len(scripts), 1, "there should be exactly one script tag")
        self.assertEqual(scripts[0].get("type"), "module")
        self.assertEqual(scripts[0].get("src"), "assets/site.js")


class Accessibility(unittest.TestCase):

    def setUp(self):
        self.page = parse()

    def test_the_document_declares_its_language(self):
        self.assertEqual([a.get("lang") for a in self.page.of("html")], ["en"])

    def test_there_is_exactly_one_h1(self):
        self.assertEqual([lvl for lvl, _ in self.page.headings].count(1), 1)

    def test_heading_levels_never_skip(self):
        levels = [lvl for lvl, _ in self.page.headings]
        for before, after in zip(levels, levels[1:]):
            self.assertLessEqual(after - before, 1, "h%d is followed by h%d" % (before, after))

    def test_the_h1_is_not_followed_by_an_h3(self):
        levels = [lvl for lvl, _ in self.page.headings]
        self.assertEqual(levels[0], 1)
        self.assertEqual(levels[1], 2, "the h1 is followed by h%d" % levels[1])

    def test_the_skip_link_is_first_and_points_at_the_main_landmark(self):
        anchors = [a for t, a in self.page.tags if t == "a"]
        self.assertEqual(anchors[0].get("href"), "#main")
        self.assertIn("main", self.page.ids)
        self.assertEqual(len(self.page.of("main")), 1)

    def test_the_skip_link_is_reachable_rather_than_display_none(self):
        block = re.search(r"\.skip\s*\{([^}]*)\}", css())
        self.assertIsNotNone(block)
        self.assertNotIn("display:none", block.group(1).replace(" ", ""))
        self.assertIn(".skip:focus", css())

    def test_every_image_carries_an_alt_attribute(self):
        for a in self.page.of("img"):
            self.assertIn("alt", a, "%s has no alt attribute" % a.get("src"))

    def test_content_images_have_describing_alt_text(self):
        for a in self.page.of("img"):
            src, alt = a.get("src", ""), a.get("alt", "")
            if "bar-" in src or "search-" in src:
                self.assertGreater(len(alt), 30, "%s needs descriptive alt text" % src)

    def test_images_declare_their_intrinsic_size(self):
        for a in self.page.of("img"):
            self.assertIn("width", a, "%s has no width" % a.get("src"))
            self.assertIn("height", a, "%s has no height" % a.get("src"))

    def test_the_navigation_landmark_is_labelled(self):
        for a in self.page.of("nav"):
            self.assertTrue(a.get("aria-label") or a.get("aria-labelledby"),
                            "an unlabelled nav is indistinguishable from any other")

    def test_table_headers_are_scoped(self):
        for a in self.page.of("th"):
            self.assertIn(a.get("scope"), ("col", "row"))

    def test_the_decorative_ruler_is_hidden_from_assistive_technology(self):
        raw = INDEX.read_text(encoding="utf-8")
        for cls in ("ruler-trough", "ruler-scale"):
            element = re.search(r'<div class="' + cls + r'"([^>]*)>', raw)
            self.assertIsNotNone(element, "%s is missing" % cls)
            self.assertIn('aria-hidden="true"', element.group(1))

    def test_focus_is_never_removed_and_reduced_motion_is_respected(self):
        self.assertIn(":focus-visible", css())
        self.assertNotIn("outline:none", css().replace(" ", ""))
        self.assertIn("prefers-reduced-motion", css())

    def test_the_layout_has_a_narrow_breakpoint_and_a_viewport_tag(self):
        self.assertIn("max-width:30rem", css().replace(" ", ""))
        viewport = [a for a in self.page.of("meta") if a.get("name") == "viewport"]
        self.assertEqual(len(viewport), 1)
        self.assertIn("width=device-width", viewport[0]["content"])

    def test_nothing_is_pinned_to_a_width_wider_than_a_320px_screen(self):
        for match in re.finditer(r"(?<!max-)(?<!min-)width:\s*(\d+)px", css()):
            self.assertLessEqual(int(match.group(1)), 320,
                                 "a fixed width of %spx overflows 320px" % match.group(1))

    def test_the_section_rhythm_is_not_cancelled_by_the_container_class(self):
        """The specificity trap this stylesheet fell into once.

        `section { padding-block: 4.5rem }` is an ELEMENT selector; `.page { padding: 0
        1.25rem }` is a CLASS selector and the shorthand writes all four sides. Every
        `<section class="page">` had its vertical padding collapsed to zero and the
        sections collided. The fix is `padding-inline`.
        """
        for selector in (".page", ".spine"):
            block = re.search(re.escape(selector) + r"\s*\{([^}]*)\}", css())
            if block is None:
                continue
            self.assertIsNone(re.search(r"(?<![\w-])padding:", block.group(1)),
                              "%s uses the padding shorthand, which cancels section's "
                              "padding-block at higher specificity" % selector)
        self.assertIn("section{padding-block", css().replace(" ", ""))

    def test_the_disclosure_is_native_so_it_works_without_javascript(self):
        raw = INDEX.read_text(encoding="utf-8")
        self.assertIn("<details class=\"deep\">", raw)
        self.assertIn("<summary>", raw)
        self.assertEqual(raw.count("<details"), raw.count("</details>"))


class Ordering(unittest.TestCase):
    """Review item 1: purpose first, then the story, then the catalogue."""

    def setUp(self):
        self.raw = INDEX.read_text(encoding="utf-8")

    def positions(self):
        return {m.group(1): m.start()
                for m in re.finditer(r'<section id="(\w+)"', self.raw)}

    def test_funding_and_the_letter_come_before_the_feature_catalogue(self):
        at = self.positions()
        self.assertLess(at["funding"], at["app"], "the catalogue comes before the goal")
        self.assertLess(at["funding"], at["privacy"])
        self.assertLess(at["research"], at["app"], "the catalogue comes before the story")
        self.assertLess(at["app"], at["pro"])

    def test_the_purpose_and_the_goal_are_in_the_first_screen(self):
        text = visible(hero())
        self.assertIn("i'm antreas", text)
        self.assertIn("us$250,000 in net sales proceeds", text)
        self.assertIn("axiotic", text)
        self.assertIn("independent ai research", text)
        self.assertIn('href="#funding"', hero())

    def test_the_hero_still_describes_the_product_and_shows_the_real_screenshot(self):
        text = visible(hero())
        self.assertIn("clipboard manager for macos", text)
        self.assertIn("by meaning", text)
        self.assertIn("your clips stay on your mac", text)
        self.assertIn("img/bar-oneDark.png", hero())
        self.assertIn("img/icon.png", hero())

    def test_the_release_status_is_two_short_lines_not_a_block(self):
        release = re.search(r'<p class="note release">(.*?)</p>', hero(), re.S)
        self.assertIsNotNone(release, "the two-line release note is missing")
        text = visible(release.group(1))
        self.assertIn("1.0.0", text)
        self.assertIn("not notarized by apple", text)
        self.assertIn("1.0.1", text)
        self.assertIn("awaiting notarization", text)
        self.assertLess(len(text.split()), 90, "the release note is a wall again")
        self.assertNotIn('class="status"', self.raw)
        self.assertNotIn("where the release actually stands", visible(self.raw))

    def test_the_macos_requirement_survives(self):
        self.assertIn("macos 13 ventura or later", visible(self.raw))
        self.assertIn("apple silicon and intel", visible(self.raw))

    def test_apple_acceptance_is_not_described_as_publishing_anything(self):
        text = visible(self.raw)
        self.assertIn("it will not appear until i publish it", text)
        for wrong in ["once apple approves it will", "will be released automatically",
                      "automatically published", "goes live when apple"]:
            self.assertNotIn(wrong, text)


class UnverifiedClaims(unittest.TestCase):
    """Review item 2: the page may not assert things about the world it cannot check."""

    def setUp(self):
        self.text = visible(INDEX.read_text(encoding="utf-8"))

    def test_no_claim_that_nothing_has_been_sold_or_that_no_shop_exists(self):
        for claim in ["nothing has been sold", "neither sales channel is open",
                      "not open yet", "open, nothing reconciled yet", "no sales have",
                      "there is nothing to buy on this page",
                      "no purchase link anywhere on it", "no checkout exists",
                      "the shop is not open", "no one has bought"]:
            self.assertNotIn(claim, self.text, "unverified claim: %s" % claim)

    def test_the_absent_counter_states_only_what_is_known(self):
        self.assertIn("no reconciled reports available", self.text)

    def test_both_channel_rows_are_neutral(self):
        funding = section("funding")
        for cid in ("app_store", "lemon_squeezy"):
            row = re.search(r'<dd data-channel="%s">([^<]*)</dd>' % cid, funding)
            self.assertIsNotNone(row, "no row for %s" % cid)
            self.assertEqual(row.group(1).strip(), "Awaiting reconciled reports")

    def test_the_renderer_uses_the_same_neutral_wording(self):
        funding_js = (DOCS / "assets" / "funding.js").read_text(encoding="utf-8")
        self.assertIn("no_reports: NEUTRAL_CHANNEL", funding_js)
        self.assertIn('NEUTRAL_CHANNEL = "Awaiting reconciled reports"', funding_js)
        # Comments stripped, so the comment EXPLAINING why `not_live` was removed is not
        # mistaken for a use of it.
        code = strip_comments(funding_js)
        for claim in ("not_live", "not open", "nothing sold", "closed"):
            self.assertNotIn(claim, code, "the renderer still asserts %r" % claim)
        py = strip_comments(
            (REPO / "tools/funding/publish_net_sales.py").read_text(encoding="utf-8"))
        self.assertNotIn("not_live", py)

    def test_the_metadata_describes_intent_rather_than_present_trade(self):
        metas = [a.get("content", "") for a in parse().of("meta")
                 if a.get("name") == "description" or a.get("property") == "og:description"]
        self.assertEqual(len(metas), 2)
        for content in metas:
            lower = content.lower()
            self.assertIn("intended", lower, "the metadata does not frame this as intent")
            self.assertIn("US$250,000", content)
            for wrong in ["buying it funds", "buy now", "on sale", "funds raised",
                          "we have raised", "customers"]:
                self.assertNotIn(wrong, lower, "metadata asserts present trade: %s" % wrong)


class CopyHygiene(unittest.TestCase):
    """Review item 3: no invented autobiography, no unsupported performance claims, no
    licence plumbing or operational asides in customer copy."""

    def setUp(self):
        self.text = visible(INDEX.read_text(encoding="utf-8"))

    def test_the_invented_autobiography_is_gone(self):
        for invented in ["app i use most", "started as an irritation",
                         "became the app i use", "my favourite app",
                         "i use it every day", "scratch my own itch",
                         "arrived alongside it"]:
            self.assertNotIn(invented, self.text, "invented detail: %s" % invented)

    def test_the_research_question_is_present_tense_not_a_chronology(self):
        # The AI research predates Cliphoard, so a question that "arrived alongside" the
        # app invents the order of events.
        self.assertIn("the question behind my work is separate, and it came first",
                      self.text)
        self.assertIn("how much useful intelligence can we put on a computer people "
                      "already own", self.text)

    def test_no_unsupported_instantaneous_performance_claim(self):
        for claim in ["instant", "instantly", "instantaneous", "zero latency",
                      "no delay", "blazing", "lightning"]:
            self.assertNotIn(claim, self.text, "unsupported performance claim: %s" % claim)

    def test_the_every_build_behaves_as_free_claim_is_gone(self):
        for claim in ["every build behaves as free", "all builds behave as free",
                      "behaves as free"]:
            self.assertNotIn(claim, self.text)

    def test_licence_plumbing_is_not_customer_copy(self):
        for internal in ["public key compiled into the app", "compiled into the app",
                         "licence server", "license server", "activation call",
                         "activation request", "nothing anyone could switch off",
                         "ed25519", "offline against a public key",
                         "probe command", "--import-probe", "run a probe"]:
            self.assertNotIn(internal, self.text, "implementation detail: %s" % internal)

    def test_purchasing_is_described_in_the_agreed_words(self):
        self.assertIn("pro purchasing is being prepared. the intended upgrade is a "
                      "one-time purchase. a verified purchase link will appear here "
                      "when ready.", self.text)
        for removed in ["the button is ahead of the shop", "ahead of the shop",
                        "if you arrived here from a get pro button",
                        "there is nothing to buy", "no purchase link anywhere"]:
            self.assertNotIn(removed, self.text, "operational aside survived: %s" % removed)

    def test_there_is_no_purchase_link_or_store_badge_anywhere(self):
        raw = INDEX.read_text(encoding="utf-8").lower()
        for needle in ["lemonsqueezy", "lemon-squeezy.com", "buy.stripe", "paddle.com",
                       "apps.apple.com", "itunes.apple.com", "app-store-badge",
                       "gumroad", "paypal", "github.com/sponsors", "patreon",
                       "buymeacoffee", "ko-fi"]:
            self.assertNotIn(needle, raw, "a purchase or donation route is linked: %s" % needle)

    def test_no_price_is_promised(self):
        # A bare "$10" also matches "$100k" on the ruler's axis, so the check is anchored.
        self.assertIsNone(re.search(r"\$10\b(?!0)", self.text), "a $10 price is quoted")
        self.assertIsNone(re.search(r"\$\d+\s*(?:/|per|a)\s*(?:month|year|mo\b)", self.text))
        for shape in ["subscription for", "/month", "monthly plan", "price: $"]:
            self.assertNotIn(shape, self.text)

    def test_the_pro_table_is_attributed_to_the_unpublished_build(self):
        self.assertIn("this is the split in the 1.0.1 build, which is not published yet",
                      self.text)
        self.assertIn("it does not describe the 1.0.0 download above", self.text)


class CodeBackedClaims(unittest.TestCase):
    """Claims with code behind them are checked against the code."""

    def setUp(self):
        self.text = visible(INDEX.read_text(encoding="utf-8"))

    def test_the_gated_features_are_on_the_pro_side_and_gated_in_the_source(self):
        deep = (REPO / "Sources/Cliphoard/Search/DeepSearch.swift").read_text(encoding="utf-8")
        self.assertIn("allCases.filter { !$0.usesImageModel || entitlement.isPro }", deep)
        store = (REPO / "Sources/Cliphoard/Clipboard/ClipStore.swift").read_text(encoding="utf-8")
        self.assertIn("entitlement.isPro && imageUnderstandingEnabled", store)
        raw = INDEX.read_text(encoding="utf-8")
        for row in ["Finding a picture by describing it",
                    "Reading the text inside your screenshots",
                    "Clips that look like this one"]:
            match = re.search(re.escape(row) + r".*?</tr>", raw, re.S)
            self.assertIsNotNone(match, "the %r row is missing" % row)
            self.assertIn('class="no">No', match.group(0),
                          "%r is not marked unavailable on Free" % row)

    def test_the_free_export_claim_matches_the_gate(self):
        gate = (REPO / "Sources/Cliphoard/Support/ProGate.swift").read_text(encoding="utf-8")
        self.assertIn("static var allowsHistoryArchive: Bool { true }", gate)
        self.assertIn("free, in both directions", self.text)

    def test_unlimited_history_is_described_as_an_option_not_the_default(self):
        self.assertIn("the limit starts at 200 clips", self.text)
        self.assertIn("one of the options rather than the default", self.text)
        self.assertIn("unlimited-history option", self.text)
        for wrong in ["unlimited history by default", "unlimited by default",
                      "no limit by default"]:
            self.assertNotIn(wrong, self.text)

    def test_only_the_three_verified_importers_are_called_verified(self):
        source = (REPO / "Sources/Cliphoard/Support/ClipImporters.swift").read_text(encoding="utf-8")
        self.assertEqual(source.count("confidence: .verified"), 3,
                         "the number of verified importers changed; the page must too")
        self.assertIn("three are verified against real installs", self.text)
        self.assertIn("paste, maccy and flycut", self.text)
        for overclaim in ["all ten verified", "ten verified", "every importer is verified"]:
            self.assertNotIn(overclaim, self.text)

    def test_the_page_does_not_claim_zero_network_calls(self):
        self.assertNotIn("zero network calls", self.text)
        self.assertNotIn("no network calls", self.text)
        self.assertIn("downloading a search model you have chosen and do not have yet",
                      self.text)

    def test_touch_id_is_described_as_absent_rather_than_promised(self):
        self.assertIn("there is no touch id prompt anywhere in cliphoard", self.text)
        self.assertNotIn("touch id hiding is planned", self.text)

    def test_the_page_does_not_tell_anyone_to_work_around_gatekeeper(self):
        for instruction in ["xattr", "com.apple.quarantine", "spctl",
                            "--master-disable", "open anyway", "allow anyway",
                            "sudo ", "right-click and open", "gatekeeper off"]:
            self.assertNotIn(instruction, self.text, "workaround: %s" % instruction)
        self.assertIn("quarantined", self.text)

    def test_the_privacy_intro_is_visitor_facing_rather_than_a_source_tour(self):
        raw = INDEX.read_text(encoding="utf-8")
        self.assertIn("nothing you copy is uploaded", self.text)
        self.assertIn("no account, no telemetry, no cloud and no sync", self.text)
        self.assertIn("encrypted on your own mac with a key that cannot leave it",
                      self.text)
        self.assertIn("privacy policy", self.text)
        self.assertIn("/blob/main/PRIVACY.md", raw)
        self.assertIn("the source", self.text)
        for removed in ["spread across the app rather than sitting in one place",
                        "the whole of the above is in one file",
                        "all of it is in one file", "it is all in crypto.swift",
                        "that part lives in", "read crypto.swift"]:
            self.assertNotIn(removed, self.text, "source-tour wording: %s" % removed)

    def test_the_models_carry_project_credits_and_their_own_licences(self):
        raw = INDEX.read_text(encoding="utf-8")
        for theirs in ["all-minilm-l6-v2", "openvision-tiny", "apple's vision framework"]:
            self.assertIn(theirs, self.text, "%s is no longer credited" % theirs)
        table = re.search(r"<tbody>.*?</tbody>", raw, re.S).group(0)
        self.assertEqual(table.count("<td>open-ogma / Antreas Antoniou</td>"), 2)
        self.assertEqual(table.count("<td>sentence-transformers</td>"), 1)
        self.assertEqual(table.count("<td>OpenVision</td>"), 1)
        self.assertNotIn("<td>Mine</td>", table)
        self.assertNotIn("<td>Not mine</td>", table)
        self.assertIn('<th scope="col">Credit</th>', raw)
        self.assertIn("cliphoard itself is mit licensed", self.text)
        self.assertIn("each one keeps its own terms and its own credit", self.text)
        for blurred in ["an mit app stays an mit app", "mit all the way down",
                        "so an mit app stays"]:
            self.assertNotIn(blurred, self.text, "licensing blurred: %s" % blurred)
        self.assertIn("apache-2.0", self.text)


class TheLetter(unittest.TestCase):
    """Review item 4."""

    def setUp(self):
        self.letter = re.search(r'<div class="letter">(.*?)\n  </div>',
                                INDEX.read_text(encoding="utf-8"), re.S).group(1)
        self.text = visible(self.letter)

    def test_the_letter_is_between_250_and_350_words(self):
        words = len(self.text.split())
        self.assertGreaterEqual(words, 250, "the letter is %d words" % words)
        self.assertLessEqual(words, 350, "the letter is %d words" % words)

    def test_it_is_first_person_and_carries_the_next_stage_himself(self):
        self.assertIn("i built cliphoard", self.text)
        self.assertIn("i'm antreas", self.text)
        self.assertIn("carrying forward on my own", self.text)
        for plural in ["our team", "our research", "our models", "we trained",
                       "we built", "we have built", "we're building", "we've built"]:
            self.assertNotIn(plural, self.text, "the letter slips into %r" % plural)

    def test_earlier_collaborators_are_acknowledged_without_invented_feeling(self):
        self.assertIn("the research i have published was done with collaborators",
                      self.text)
        self.assertIn("this next stage i am carrying forward on my own", self.text)
        for invented in ["i'm grateful", "i am grateful", "i'm proud", "i'm honoured",
                         "it means a lot", "i'll never forget"]:
            self.assertNotIn(invented, self.text, "invented feeling: %s" % invented)

    def test_the_phd_background_is_not_conflated_with_the_shipped_search(self):
        # The shipped search is two small static text embedders, not a meta-learning
        # system, so the two sentences must not run together.
        self.assertIn("my phd, at the university of edinburgh, was in machine learning "
                      "and meta-learning", self.text)
        self.assertIn("for cliphoard specifically, i trained and distilled two small "
                      "open-ogma text models from open teachers", self.text)
        for conflation in ["the search in cliphoard is one answer to that question",
                           "cliphoard is a meta-learning", "meta-learning search"]:
            self.assertNotIn(conflation, self.text, "conflation: %s" % conflation)

    def test_other_peoples_work_is_credited_in_the_letter_too(self):
        self.assertIn("openvision", self.text)
        self.assertIn("apple's vision framework", self.text)
        self.assertIn("sentence-transformers", self.text)
        self.assertIn("other people's work", self.text)

    def test_axiotic_is_described_as_high_risk_question_driven_research(self):
        self.assertIn("high-risk, high-reward foundational ai research", self.text)
        self.assertIn("worth testing", self.text)
        self.assertIn("funding currently favours", self.text)

    def test_daedalus_and_praxis_are_programmes_not_shipped_capabilities(self):
        for part in ["learns from experience", "model of its world", "remembers",
                     "reasons", "limited computation"]:
            self.assertIn(part, self.text, "Daedalus omits %s" % part)
        self.assertIn("praxis", self.text)
        self.assertIn("simulation first", self.text)
        self.assertIn("research programmes and open hypotheses", self.text)
        self.assertIn("not finished products", self.text)
        self.assertIn("neither is a capability that is in the clipboard app today",
                      self.text)

    def test_the_goal_is_tied_to_research_time_compute_evaluation_and_releases(self):
        for part in ["research time", "compute", "careful evaluation", "release a model"]:
            self.assertIn(part, self.text, "the goal's use omits %s" % part)

    def test_improvements_inside_cliphoard_are_an_aim_not_a_promise(self):
        self.assertIn("the aim is for some of it to come back here as better models "
                      "inside cliphoard", self.text)
        self.assertIn("depends on what the research turns up", self.text)
        self.assertIn("no clipboard uploads", self.text)
        for overpromise in ["some of it comes straight back here",
                            "will come back here", "without sending anything anywhere"]:
            self.assertNotIn(overpromise, self.text, "overpromise: %s" % overpromise)

    def test_no_invented_budget_split_and_no_guaranteed_outcome(self):
        self.assertIsNone(re.search(r"\d+\s*%\s*(?:of|to|for)\b", self.text),
                          "an invented budget split appeared")
        for wrong in ["guarantee", "will solve", "breakthrough", "revolutionary",
                      "agi", "cure", "heal", "therapeutic", "life-changing",
                      "that is what the word experiment means"]:
            self.assertNotIn(wrong, self.text, "overclaim or pomposity: %s" % wrong)
        self.assertIn("i can't promise which experiments will work", self.text)

    def test_the_public_links_are_present_and_no_private_one_is(self):
        raw = INDEX.read_text(encoding="utf-8")
        for url in ["https://antreas.io", "https://antreas.io/daedalus/",
                    "https://axiotic.ai", "https://github.com/axiotic-ai"]:
            self.assertIn(url, raw, "%s is missing" % url)
        for private in ["my-archivum", "forge/repos", "/Users/", "Documents/ChatGPT",
                        "agent-sync", "questlog", "bitwarden", "74M96PGT6P",
                        "notary", ".p12", "4f8c8a4c"]:
            self.assertNotIn(private, raw, "private detail leaked: %s" % private)


class TheNetExplanation(unittest.TestCase):
    """Review item 5."""

    def setUp(self):
        self.funding = section("funding")
        self.text = visible(self.funding)

    def test_there_is_a_how_the_total_is_counted_disclosure(self):
        self.assertIn("how the total is counted", self.text)

    def test_it_names_every_deduction_and_what_it_is_not(self):
        for part in ["provider-reported net sales proceeds", "after customer taxes",
                     "platform", "payment fees", "refunds", "chargebacks",
                     "reported adjustments", "before income tax", "running costs"]:
            self.assertIn(part, self.text, "the basis omits %s" % part)
        self.assertIn("not a current bank balance", self.text)

    def test_monthly_reconciliation_is_not_described_as_live(self):
        self.assertIn("reconciliation\n    is monthly".replace("\n    ", " "),
                      " ".join(self.text.split()))
        self.assertIn("rather than as a live stream", self.text)
        for wrong in ["live total", "updates live", "in real time", "as it happens",
                      "live counter"]:
            self.assertNotIn(wrong, self.text, "implies a live feed: %s" % wrong)

    def test_the_goal_is_a_milestone_not_a_cap(self):
        self.assertIn("milestone rather than a cap", self.text)
        self.assertIn("supports further research", self.text)

    def test_a_purchase_buys_software_without_a_wall_of_legal_framing(self):
        self.assertIn("buying cliphoard buys the software", self.text)
        for removed in ["this is not an investment, it is not equity",
                        "it is not a charity", "nothing on this page asks you for money"]:
            self.assertNotIn(removed, self.text, "the negative wall is back: %s" % removed)

    def test_the_explanation_is_short(self):
        block = re.search(r"<h3>How the total is counted</h3>(.*?)</section>",
                          self.funding, re.S).group(1)
        sentences = [s for s in re.split(r"(?<=\.)\s", visible(block)) if s.strip()]
        self.assertLessEqual(len(sentences), 6, "%d sentences is a wall" % len(sentences))


class FundingMarkup(unittest.TestCase):
    """The no-JavaScript rendering must already be honest, and the goal must agree with
    the ruler's fixed axis in every place that knows about it."""

    def setUp(self):
        self.raw = INDEX.read_text(encoding="utf-8")
        self.funding = section("funding")

    def test_the_static_markup_contains_no_amount_and_no_percentage(self):
        allowed = {"250,000", "250", "0", "50", "100", "150", "200"}
        for number in re.findall(r"\$\d[\d,]*\d(?:\.\d\d)?|\$\d|\b\d+%", self.funding):
            cleaned = number.lstrip("$").rstrip("%").replace("k", "")
            self.assertIn(cleaned, allowed, "%s is a figure the page cannot support" % number)
        self.assertNotIn("0%", self.funding)
        self.assertNotIn("$0.00", self.funding)

    def test_the_goal_stays_visible_without_javascript(self):
        self.assertIn("US$250,000", self.funding)
        self.assertIn("ruler-scale", self.funding)

    def test_the_figure_and_bar_are_empty_in_the_static_markup(self):
        figure = re.search(r'data-funding-figure[^>]*>([^<]*)<', self.raw).group(1).strip()
        self.assertEqual(figure, "No reconciled reports available.")
        fill = re.search(r'<div class="ruler-fill"([^>]*)>', self.raw).group(1)
        self.assertNotIn("width", fill, "the bar must not be pre-filled in the markup")

    def test_the_static_status_line_describes_the_both_channel_requirement(self):
        line = re.search(r'data-funding-status>(.*?)</p>', self.funding, re.S).group(1)
        self.assertIn("both channels", visible(line))
        self.assertIn("same period", visible(line))

    def test_the_static_markup_uses_the_renderers_own_neutral_strings(self):
        """If these drift, the reset would restore text the page never ships."""
        js = (DOCS / "assets" / "funding.js").read_text(encoding="utf-8")
        # Two of the four are written as a concatenation across a line break, so the
        # declaration is read to its semicolon and every quoted piece is joined.
        constants = {}
        for name, body in re.findall(r"export const (NEUTRAL_\w+) = ([^;]*);", js):
            constants[name] = "".join(re.findall(r'"([^"]*)"', body))
        self.assertEqual(set(constants),
                         {"NEUTRAL_FIGURE", "NEUTRAL_CHANNEL", "NEUTRAL_STATUS",
                          "NEUTRAL_ASOF"})
        flat_funding = " ".join(visible(self.funding).split())
        for name, value in constants.items():
            self.assertIn(value.lower(), flat_funding,
                          "%s is not the text the page ships" % name)

    def test_the_slots_the_renderer_writes_into_all_exist(self):
        funding = (DOCS / "assets" / "funding.js").read_text(encoding="utf-8")
        for selector in re.findall(r'\[data-(funding-[a-z]+)\]', funding):
            self.assertIn("data-%s" % selector, self.raw,
                          "the renderer targets data-%s and the page has no slot" % selector)
        ids = re.search(r"CHANNEL_IDS = \[(.*?)\]", funding, re.S).group(1)
        for channel in re.findall(r'"([a-z_]+)"', ids):
            self.assertIn('data-channel="%s"' % channel, self.raw,
                          "funding.js knows about %s and the page has no row" % channel)

    def test_the_conditional_slots_start_hidden(self):
        for slot in ("data-funding-beyond", "data-funding-stale", "data-funding-coverage"):
            element = re.search(r"<p[^>]*" + slot + r"[^>]*>", self.raw)
            self.assertIsNotNone(element, "%s is missing" % slot)
            self.assertIn("hidden", element.group(0))

    def test_the_ruler_axis_the_renderer_and_the_publisher_agree_on_the_goal(self):
        ticks = re.search(r'<div class="ruler-scale"[^>]*>(.*?)</div>',
                          self.funding, re.S).group(1)
        self.assertEqual(re.findall(r"<span>([^<]+)</span>", ticks),
                         ["$0", "$50k", "$100k", "$150k", "$200k", "$250k"])
        js = (DOCS / "assets" / "funding.js").read_text(encoding="utf-8")
        self.assertIn("GOAL_CENTS = 25000000", js)
        py = (REPO / "tools/funding/publish_net_sales.py").read_text(encoding="utf-8")
        self.assertIn('GOAL = Decimal("250000.00")', py)
        shipped = json.loads((DOCS / "data" / "net-sales.json").read_text(encoding="utf-8"))
        self.assertEqual(shipped["goal"], "250000.00")

    def test_the_production_payload_is_genuinely_unavailable(self):
        shipped = json.loads((DOCS / "data" / "net-sales.json").read_text(encoding="utf-8"))
        self.assertEqual(shipped["status"], "unavailable")
        self.assertIsNone(shipped["total_net"])
        self.assertIsNone(shipped["as_of"])
        self.assertIsNone(shipped["campaign_start"])
        self.assertEqual(shipped["coverage"]["reports"], 0)
        self.assertEqual({c["status"] for c in shipped["channels"]}, {"no_reports"})
        self.assertTrue(all(c["net"] is None for c in shipped["channels"]))


class CurrencyIsExplicit(unittest.TestCase):
    """A bare "$" does not say which dollar, and the business is UK-registered."""

    def setUp(self):
        self.text = visible(INDEX.read_text(encoding="utf-8"))

    def test_the_goal_is_stated_as_us_dollars(self):
        self.assertIn("us$250,000 in net sales proceeds", self.text)

    def test_an_all_figures_in_usd_statement_sits_beside_the_goal(self):
        self.assertIn("all figures on this page are in us dollars", visible(section("funding")))
        asof = re.search(r'data-funding-asof>(.*?)</p>', section("funding"), re.S).group(1)
        self.assertIn("in us dollars", visible(asof))

    def test_the_renderer_and_the_page_use_the_same_goal_label(self):
        js = (DOCS / "assets" / "funding.js").read_text(encoding="utf-8")
        self.assertIn('GOAL_LABEL = "US$250,000"', js)
        self.assertIn("us$250,000", self.text)

    def test_the_metadata_names_the_currency(self):
        for a in parse().of("meta"):
            content = a.get("content", "")
            if a.get("name") == "description" or a.get("property") == "og:description":
                self.assertIn("US$250,000", content)
                self.assertIn("net sales proceeds", content)

    def test_the_precise_term_is_used_rather_than_accounting_shorthand(self):
        self.assertIn("net sales proceeds", self.text)
        for vague in ["net revenue", "net earnings", "net income", "net receipts",
                      "takings", "turnover"]:
            self.assertNotIn(vague, self.text, "ambiguous shorthand: %s" % vague)


class MobileFirstScreen(unittest.TestCase):
    """The first viewport on a phone has to earn its space."""

    def setUp(self):
        self.raw = INDEX.read_text(encoding="utf-8")

    def test_the_hero_lead_is_about_twenty_five_words(self):
        lead = re.search(r'<p class="lead">(.*?)</p>', self.raw, re.S).group(1)
        words = len(re.sub(r"<[^>]+>", " ", lead).split())
        self.assertLessEqual(words, 30, "the hero lead is %d words" % words)
        self.assertGreaterEqual(words, 18, "the hero lead is %d words" % words)

    def test_the_lead_is_a_plain_product_and_privacy_statement(self):
        lead = visible(re.search(r'<p class="lead">(.*?)</p>', self.raw, re.S).group(1))
        self.assertIn("clipboard manager for macos", lead)
        self.assertIn("stay on your mac", lead)

    def test_the_mascot_shrinks_on_phones(self):
        match = re.search(r"\.hero-head img\{width:([\d.]+)rem", narrow_block())
        self.assertIsNotNone(match, "the mascot has no narrow-screen size")
        px = float(match.group(1)) * 16
        self.assertLessEqual(px, 60, "the mascot is still %.0fpx on a phone" % px)
        self.assertGreaterEqual(px, 48, "%.0fpx is too small to read as the mascot" % px)

    def test_the_headline_is_stepped_down_so_both_lines_fit_at_320px(self):
        match = re.search(r"\bh1\{font-size:([\d.]+)rem", narrow_block())
        self.assertIsNotNone(match, "the h1 has no narrow-screen step")
        px = float(match.group(1)) * 16
        # 288px of content at 320px, minus 2 x 16px padding. "Hoard everything." is 17
        # characters and a bold sans advance of ~0.55em is a conservative estimate.
        self.assertLessEqual(17 * 0.55 * px, 288,
                             "at %.0fpx the second line will not fit 320px" % px)
        self.assertIn("Copy anything.<br>Hoard everything.", self.raw)

    def test_the_download_action_and_the_goal_both_sit_in_the_hero(self):
        self.assertIn('class="btn btn-solid"', hero())
        self.assertIn("US$250,000", hero())
        self.assertIn('href="#funding"', hero())


class RulerEndpoints(unittest.TestCase):
    """The goal tick is the one label the ruler exists to carry."""

    def test_the_narrow_screen_rule_does_not_hide_an_endpoint(self):
        # Observed live at 318px: `span:nth-child(even)` hides the SIXTH span, which is
        # $250k, so a phone showed $0, $100k and $200k and no goal at all.
        hidden = re.findall(r"\.ruler-scale span:nth-child\((\w+)\)\s*[,{]", css())
        self.assertNotIn("even", hidden,
                         "nth-child(even) hides the sixth span, which is the goal tick")
        self.assertTrue(hidden, "the thinning rule disappeared entirely")
        for index in hidden:
            self.assertIn(index, {"2", "3", "4", "5"},
                          "nth-child(%s) can hit an endpoint of a six-tick scale" % index)

    def test_the_endpoints_are_forced_visible_after_any_thinning(self):
        flat_css = css().replace("\n", " ")
        rule = re.search(r"\.ruler-scale span:first-child,\s*"
                         r"\.ruler-scale span:last-child\{([^}]*)\}", flat_css)
        self.assertIsNotNone(rule, "nothing guarantees the endpoints stay visible")
        self.assertIn("visibility:visible", rule.group(1).replace(" ", ""))
        self.assertGreater(flat_css.index("span:first-child,"),
                           flat_css.index("span:nth-child(2)"),
                           "the guarantee comes before the thinning and cannot win")

    def test_thinning_uses_visibility_so_the_survivors_keep_their_positions(self):
        ruler = [line for line in narrow_block().split("\n") if "ruler-scale" in line]
        self.assertTrue(ruler)
        self.assertNotIn("display:none", " ".join(ruler))

    def test_all_six_ticks_are_in_the_markup(self):
        ticks = re.search(r'<div class="ruler-scale"[^>]*>(.*?)</div>',
                          section("funding"), re.S).group(1)
        self.assertEqual(re.findall(r"<span>([^<]+)</span>", ticks),
                         ["$0", "$50k", "$100k", "$150k", "$200k", "$250k"])


class QAHarness(unittest.TestCase):
    """Review item 15, plus the two defects the live pass found in it."""

    def setUp(self):
        self.raw = HARNESS.read_text(encoding="utf-8")

    def test_the_harness_exists_outside_the_published_site(self):
        self.assertTrue(HARNESS.is_file())
        self.assertFalse((DOCS / "preview.html").exists(),
                         "a harness inside docs/ would be served by GitHub Pages")
        self.assertEqual([p for p in DOCS.rglob("*") if "preview" in p.name], [])

    def test_the_synthetic_banner_is_present_and_has_no_dismiss_control(self):
        banner = re.search(r'<div class="synthetic"[^>]*>(.*?)</div>', self.raw, re.S)
        self.assertIsNotNone(banner, "no synthetic banner")
        self.assertIn("synthetic test harness", visible(banner.group(1)))
        self.assertIn("fake", visible(banner.group(1)))
        self.assertIn("local only", visible(banner.group(1)))
        for control in ["remove()", "hidden = true", 'style.display = "none"',
                        "closeBanner", "dismissBanner"]:
            self.assertNotIn(control, self.raw, "the banner can be hidden via %s" % control)

    def test_it_frames_the_real_site_by_a_relative_path(self):
        src = re.search(r'<iframe id="site" src="([^"]+)"', self.raw).group(1)
        self.assertEqual(src, "../../docs/")
        self.assertTrue((HARNESS.parent / src).resolve().is_dir())

    def test_the_required_fixtures_are_offered(self):
        fixtures = set(re.findall(r'data-fixture="(\w+)"', self.raw))
        self.assertTrue({"unavailable", "zero", "over", "double", "stale", "invalid"}
                        <= fixtures, "missing fixtures: %s" % fixtures)

    def test_it_drives_the_real_module_rather_than_reimplementing_it(self):
        self.assertIn('from "../../docs/assets/funding.js"', self.raw)
        self.assertIn("applyFundingView", self.raw)
        self.assertIn("fundingView(payload, today)", self.raw)
        for reimplementation in ["function formatUSD", "function toCents",
                                 "toFixed(2)", "/ 100).toLocaleString"]:
            self.assertNotIn(reimplementation, self.raw,
                             "the harness reimplements %s" % reimplementation)

    def test_every_fixture_amount_is_labelled_synthetic(self):
        self.assertIn("SYNTHETIC QA FIXTURE", self.raw)
        self.assertIn("All amounts are fake.", self.raw)

    def test_no_production_query_flag_exists_on_the_site(self):
        for flag in ["location.search", "URLSearchParams", "?fixture", "?demo",
                     "?preview", "debug=true"]:
            for path in (INDEX, DOCS / "assets" / "site.js",
                         DOCS / "assets" / "funding.js"):
                self.assertNotIn(flag, path.read_text(encoding="utf-8"),
                                 "%s reads %s; a fixture must not be reachable from "
                                 "the published site" % (path.name, flag))

    def test_no_fixture_amount_is_in_the_published_data(self):
        # Whole money VALUES, not substrings: "0.00" is a substring of "250000.00".
        shipped = json.loads((DOCS / "data" / "net-sales.json").read_text(encoding="utf-8"))
        published = {shipped["total_net"]} | {c["net"] for c in shipped["channels"]}
        published.discard(None)
        fixtures = set(re.findall(r'"(\d+\.\d\d)"', self.raw)) - {"250000.00"}
        self.assertEqual(published & fixtures, set(),
                         "a harness fixture amount reached the published data")

    def test_the_harness_runs_no_automation_and_takes_no_screenshots(self):
        for forbidden in ["puppeteer", "playwright", "webdriver", "captureScreenshot",
                          "html2canvas", 'fetch("http', "XMLHttpRequest"]:
            self.assertNotIn(forbidden, self.raw)


class HarnessViewportAndNavigation(unittest.TestCase):
    """The two defects the live Chrome pass found in the harness itself."""

    def setUp(self):
        self.raw = HARNESS.read_text(encoding="utf-8")

    def test_the_iframe_uses_an_outline_so_the_viewport_is_the_selected_width(self):
        # Observed live: "320" produced a 318px viewport, because the global
        # `box-sizing: border-box` put the 1px border INSIDE the iframe's box. An outline
        # is painted outside the layout box and costs nothing.
        rule = re.search(r"\n  iframe\{([^}]*)\}", self.raw)
        self.assertIsNotNone(rule, "no iframe rule")
        body = rule.group(1).replace("\n", " ")
        self.assertIn("border:0", body.replace(" ", ""))
        self.assertIn("outline:", body)
        self.assertIsNone(re.search(r"(?<![-\w])border:\s*1px", body),
                          "the border is back inside the box")
        self.assertNotIn("max-width", body,
                         "max-width silently shrinks 1440 to the window width")

    def test_the_stage_scrolls_so_the_widest_setting_is_reachable(self):
        rule = re.search(r"\.stage\{([^}]*)\}", self.raw).group(1)
        self.assertIn("overflow-x:auto", rule.replace(" ", ""))

    def test_the_readback_reports_the_requested_width_alongside_the_measured_one(self):
        for token in ["requested", "viewport", "scrollWidth", "h-overflow", "exact",
                      "innerWidth"]:
            self.assertIn(token, self.raw, "the readback omits %s" % token)

    def test_the_four_required_widths_are_offered(self):
        widths = re.findall(r'data-width="(\d+)"', self.raw)
        self.assertEqual(sorted(map(int, widths)), [320, 390, 768, 1440])

    def test_the_four_jump_controls_target_real_anchors(self):
        jumps = re.findall(r'data-jump="(\w+)"', self.raw)
        self.assertEqual(jumps, ["top", "funding", "research", "pro"])
        ids = parse().ids
        for target in jumps:
            self.assertIn(target, ids, "the framed page has no #%s" % target)
        # It scrolls the FRAMED document, because a locator at the root level cannot
        # reach inside the frame.
        self.assertIn("framedDocument()", self.raw)
        self.assertIn("scrollIntoView", self.raw)

    def test_the_jump_labels_are_the_ones_asked_for(self):
        for label in ["Top", "Funding", "Research", "Free and Pro"]:
            self.assertIn(">%s</button>" % label, self.raw, "no %r button" % label)

    def test_the_fixture_log_reports_the_reset_honestly(self):
        # The transition that was broken: 500,000 then unavailable left the figure up.
        self.assertIn("page reset to neutral", self.raw)
        self.assertIn("figure rendered", self.raw)
        self.assertIn("{ rendered, reset }", self.raw)
        self.assertNotIn("page updated=", self.raw)

    def test_the_harness_explains_the_reset_transition_without_a_reload(self):
        prose = visible(self.raw)
        self.assertIn("$500,000.00", prose)
        self.assertIn("no reconciled reports available", prose)
        self.assertIn("with no reload", prose)


class TheResetIsWiredEverywhere(unittest.TestCase):
    """The DOM behaviour is regressed in the Node suite; this pins the WIRING, so the
    reset cannot be quietly removed from a path without a test noticing."""

    def setUp(self):
        self.js = (DOCS / "assets" / "funding.js").read_text(encoding="utf-8")

    def test_there_is_exactly_one_reset_function_and_it_is_exported(self):
        self.assertEqual(self.js.count("export function resetFundingView"), 1)

    def test_the_reset_restores_every_slot_the_success_path_writes(self):
        body = re.search(r"export function resetFundingView.*?\n\}", self.js, re.S).group(0)
        for name in ["figure", "percent", "fill", "status", "asof", "beyond", "stale",
                     "coverage"]:
            self.assertIn('"%s"' % name, body, "the reset leaves data-funding-%s" % name)
        self.assertIn("NEUTRAL_FIGURE", body)
        self.assertIn("NEUTRAL_CHANNEL", body)
        self.assertIn("NEUTRAL_STATUS", body)
        self.assertIn("NEUTRAL_ASOF", body)
        self.assertIn("GOAL_LABEL", body)
        self.assertIn('classList.add("absent")', body)
        self.assertIn('classList.remove("amount")', body)
        self.assertIn('width = "0%"', body)

    def test_the_reset_clears_as_well_as_hides(self):
        body = re.search(r"export function resetFundingView.*?\n\}", self.js, re.S).group(0)
        clear = re.search(r'for \(const name of \["beyond", "stale", "coverage"\]\)'
                          r"(.*?)\n  \}", body, re.S)
        self.assertIsNotNone(clear, "beyond/stale/coverage are not cleared in a loop")
        self.assertIn('textContent = ""', clear.group(1))
        self.assertIn("hidden = true", clear.group(1))

    def test_an_unavailable_or_invalid_view_resets_rather_than_no_opping(self):
        body = re.search(r"export function applyFundingView.*?\n\}", self.js, re.S).group(0)
        guard = re.search(r"if \(!view \|\| !view\.ok \|\| view\.state === "
                          r'"unavailable"\) \{(.*?)\n  \}', body, re.S)
        self.assertIsNotNone(guard, "there is no unavailable/invalid guard")
        self.assertIn("resetFundingView(root)", guard.group(1))
        self.assertIn("reset: true", guard.group(1))

    def test_every_boot_failure_path_resets(self):
        body = re.search(r"export async function bootFunding.*?\n\}", self.js, re.S).group(0)
        self.assertEqual(body.count("resetFundingView(root)"), 2,
                         "a boot failure path does not reset")
        self.assertIn("if (hasDuplicateKeys(text)) throw", body)
        self.assertIn("if (!response.ok) throw", body)
        self.assertIn("} catch {", body)

    def test_the_duplicate_key_scan_decodes_before_comparing(self):
        self.assertIn("readJSONString", self.js)
        self.assertIn("String.fromCharCode(parseInt(", self.js)
        scan = re.search(r"export function hasDuplicateKeys.*?\n\}", self.js, re.S).group(0)
        self.assertIn("readJSONString(text, i)", scan)
        self.assertNotIn("raw +=", scan, "the scan still accumulates raw characters")


class ClaimMirror(unittest.TestCase):
    """The sentences Tests/CliphoardTests/DocsLaunchClaimTests.swift pins inside
    docs/index.html, mirrored so they are verifiable without an app build."""

    def setUp(self):
        self.text = flat(INDEX)

    def test_the_pinned_sentences_survive(self):
        for anchor in [
            "the app you copied from, images and the semantic search index — is sealed "
            "with authenticated aes-gcm",
            "key from your passphrase (pbkdf2-hmac-sha256",
            "the passphrase is the only key — there is no recovery",
            "1.0.1", "export", "aes-256-gcm", "pbkdf2", "600,000",
        ]:
            self.assertIn(anchor, self.text,
                          "DocsLaunchClaimTests pins this and it is gone: %s" % anchor[:60])

    def test_the_retired_wording_stays_retired(self):
        for stale in ["point the store", "synced folder",
                      "never stored in the first place", "you get nothing",
                      "skipped automatically", "encrypted export/import is planned",
                      "there is no export or import", "there is no export yet",
                      "export/import is planned for 1.0.1"]:
            self.assertNotIn(stale, self.text, "retired wording is back: %s" % stale)


if __name__ == "__main__":
    unittest.main(verbosity=2)
