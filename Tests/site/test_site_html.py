#!/usr/bin/env python3.13
"""Production-page contracts for the owner-selected Flow design.

These checks cover link resolution, accessible structure, release and purchase facts,
privacy boundaries, neutral funding state, and the System/Light/Dark theme paths.
Visual spacing and actual responsive fit are inspected in Chrome; a CSS substring or
an estimated glyph width is not evidence that a layout fits.

Run: /opt/homebrew/bin/python3.13 -m unittest discover -s Tests/site -p 'test_*.py'
"""

import json
import re
import unittest
from html import unescape
from html.parser import HTMLParser
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
DOCS = REPO / "docs"
INDEX = DOCS / "index.html"
HARNESS = REPO / "Tests" / "site" / "preview.html"


class Collector(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.tags = []
        self.ids = []
        self.headings = []
        self._heading = None
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


def parse(path=INDEX):
    c = Collector()
    c.feed(path.read_text(encoding="utf-8"))
    return c


def flat(path):
    """The same normalization as DocsLaunchClaimTests.swift."""
    s = path.read_text(encoding="utf-8").lower()
    for tag in ("<b>", "</b>", "<i>", "</i>", "**", "*"):
        s = s.replace(tag, "")
    return " ".join(s.split())


def section(name):
    """Return the element with this id, including nested elements of the same tag.

    Flow has an install section inside its hero and a funding section inside research;
    stopping at the first closing section would silently inspect only half the page.
    """
    raw = INDEX.read_text(encoding="utf-8")
    start = re.search(r'<([a-z][a-z0-9-]*)\b[^>]*\bid="' + re.escape(name) + r'"[^>]*>', raw)
    assert start, "no #%s element" % name
    tag, depth = start.group(1), 1
    for token in re.finditer(r'</?' + re.escape(tag) + r'\b[^>]*>', raw[start.end():]):
        depth += -1 if token.group(0).startswith("</") else 1
        if depth == 0:
            return raw[start.start():start.end() + token.end()]
    raise AssertionError("unclosed #%s element" % name)


def hero():
    return section("top")


def strip_comments(source):
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    source = re.sub(r'"""[\s\S]*?"""', "", source)
    return "\n".join(line for line in source.split("\n")
                     if not line.lstrip().startswith(("//", "#")))


def visible(html):
    body = re.sub(r"<!--.*?-->", " ", html, flags=re.S)
    return " ".join(unescape(re.sub(r"<[^>]+>", " ", body)).lower().split())


def stylesheet_paths():
    return [DOCS / a["href"].split("?")[0] for a in parse().of("link")
            if a.get("rel") == "stylesheet"]


def css():
    return "\n".join(path.read_text(encoding="utf-8") for path in stylesheet_paths())


def appearance_js():
    return (DOCS / "assets/appearance.js").read_text(encoding="utf-8")


def declarations(block):
    pairs = {}
    for piece in re.sub(r"/\*.*?\*/", "", block, flags=re.S).split(";"):
        name, sep, value = piece.partition(":")
        if sep and name.strip():
            pairs[name.strip()] = value.strip()
    return pairs


def css_block(source, pattern):
    """Extract a brace-delimited block, preserving nested media rules."""
    match = re.search(pattern, source)
    assert match, "missing CSS block: %s" % pattern
    opening = source.index("{", match.start())
    depth = 1
    for i in range(opening + 1, len(source)):
        depth += (source[i] == "{") - (source[i] == "}")
        if depth == 0:
            return source[opening + 1:i]
    raise AssertionError("unclosed CSS block")


def palette(which):
    sheet = (DOCS / "assets/flow.css").read_text(encoding="utf-8")
    patterns = {
        "light": r"(?:^|\n):root\s*\{",
        "chosen-dark": r':root\[data-theme="dark"\]\s*\{',
        "system-dark": r':root:not\(\[data-theme="light"\]\)\s*\{',
    }
    return declarations(css_block(sheet, patterns[which]))


def expand_hex(value):
    if re.fullmatch(r"#[0-9a-fA-F]{3}", value):
        return "#" + "".join(c * 2 for c in value[1:])
    return value


def colours(which):
    return {name: expand_hex(value) for name, value in palette(which).items()
            if value.startswith("#")}


def relative_luminance(value):
    value = expand_hex(value)
    channels = [int(value[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
              for c in channels]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def contrast(one, two):
    a, b = relative_luminance(one), relative_luminance(two)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)


def specificity(selector):
    arguments = re.findall(r":not\(([^)]*)\)", selector)
    bare = re.sub(r":not\([^)]*\)", "", selector)
    found = (bare.count("#"),
             len(re.findall(r"\[[^\]]*\]", bare)) + bare.count(".")
             + len(re.findall(r"(?<!:):[a-z-]+", bare)),
             len(re.findall(r"^[a-z]+", bare)))
    for argument in arguments:
        found = tuple(a + b for a, b in zip(found, specificity(argument)))
    return found


def root_matches(selector, data_theme):
    if selector == ":root":
        return True
    attribute = re.fullmatch(r':root\[data-theme="(\w+)"\]', selector)
    if attribute:
        return data_theme == attribute.group(1)
    negated = re.fullmatch(r':root:not\(\[data-theme="(\w+)"\]\)', selector)
    if negated:
        return data_theme != negated.group(1)
    raise AssertionError("unmodelled root selector: %s" % selector)


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
    def script_paths(self):
        paths = [DOCS / a["src"] for a in parse().of("script") if a.get("src")]
        return paths + [DOCS / "assets/funding.js"]

    def test_no_executable_or_style_dependency_comes_from_another_origin(self):
        for tag, a in parse().tags:
            if tag == "script":
                self.assertIn("src", a, "inline script appeared")
                self.assertFalse(a["src"].startswith(("http", "//")))
            if tag == "link" and a.get("rel") in ("stylesheet", "preload", "modulepreload"):
                self.assertFalse(a["href"].startswith(("http", "//")))
            self.assertFalse(any(key.startswith("on") for key in a), "inline handler appeared")
            self.assertFalse(a.get("href", "").lower().startswith("javascript:"))

    def test_no_webfont_or_import_is_requested(self):
        sheet = strip_comments(css())
        for forbidden in ("@font-face", "@import", "fonts.googleapis", "fonts.gstatic", "typekit"):
            self.assertNotIn(forbidden, sheet)

    def test_no_tracking_or_embedded_service_is_present(self):
        raw = INDEX.read_text(encoding="utf-8").lower()
        for needle in ("<iframe", "google-analytics", "googletagmanager", "gtag(",
                       "plausible", "fathom", "hotjar", "tracking pixel", "1x1.",
                       "localstorage", "document.cookie", "navigator.sendbeacon"):
            self.assertNotIn(needle, raw)

    def test_only_the_appearance_preference_is_stored_and_never_transmitted(self):
        for path in self.script_paths():
            code = strip_comments(path.read_text(encoding="utf-8"))
            for forbidden in ("document.cookie", "sendBeacon", "navigator.userAgent",
                              "Math.random", "crypto.randomUUID", "XMLHttpRequest",
                              "indexedDB", "sessionStorage", "gtag(", "new Image("):
                self.assertNotIn(forbidden, code, "%s uses %s" % (path.name, forbidden))
            if path.name != "appearance.js":
                self.assertNotIn("localStorage", code, "%s adds storage" % path.name)
            if path.name != "funding.js":
                self.assertNotIn("fetch(", code, "%s adds a network call" % path.name)
        code = strip_comments(appearance_js())
        self.assertEqual(re.findall(r'var KEY = "([^"]+)"', code), ["cliphoard.appearance"])
        for method, args in re.findall(r"localStorage\.(\w+)\(([^)]*)\)", code):
            self.assertIn(method, ("getItem", "setItem", "removeItem"))
            self.assertTrue(args.startswith("KEY"))

    def test_the_named_local_scripts_load_with_only_the_theme_bootstrap_blocking(self):
        scripts = parse().of("script")
        self.assertEqual([a.get("src") for a in scripts], [
            "assets/appearance.js", "assets/shared.js", "assets/product-details.js",
            "assets/get-started.js", "assets/site.js",
        ])
        self.assertNotIn("async", scripts[0])
        self.assertNotIn("defer", scripts[0])
        self.assertNotIn("type", scripts[0])
        for script in scripts[1:]:
            self.assertTrue("defer" in script or script.get("type") == "module")
        raw = INDEX.read_text(encoding="utf-8")
        self.assertLess(raw.index('src="assets/appearance.js"'), raw.index('rel="stylesheet"'))
        self.assertLess(raw.index('src="assets/appearance.js"'), raw.index("<body"))

    def test_the_demo_never_reads_the_visitors_clipboard(self):
        for path in self.script_paths():
            code = strip_comments(path.read_text(encoding="utf-8"))
            self.assertNotRegex(code, r"clipboard\s*\.\s*read(?:Text)?\s*\(")
        self.assertIn("doesn’t read your clipboard", visible(section("preview")))
        self.assertEqual(len(parse().of("clip-demo")), 1)
        self.assertEqual(parse().of("clip-demo")[0].get("data-examples"), "everyday")


class Accessibility(unittest.TestCase):
    def setUp(self):
        self.page = parse()

    def test_language_and_heading_hierarchy(self):
        self.assertEqual([a.get("lang") for a in self.page.of("html")], ["en"])
        levels = [level for level, _ in self.page.headings]
        self.assertEqual(levels.count(1), 1)
        self.assertEqual(levels[0], 1)
        for before, after in zip(levels, levels[1:]):
            self.assertLessEqual(after - before, 1, "h%d is followed by h%d" % (before, after))

    def test_the_first_link_skips_to_the_single_main_landmark(self):
        self.assertEqual(self.page.of("a")[0].get("href"), "#main")
        self.assertEqual([a.get("id") for a in self.page.of("main")], ["main"])
        self.assertIn(".f-skip:focus", css())
        self.assertNotIn("display:none", css_block(css(), r"\.f-skip\s*\{"))

    def test_every_image_has_alt_text_and_intrinsic_dimensions(self):
        for a in self.page.of("img"):
            self.assertTrue({"alt", "width", "height"} <= set(a), a.get("src"))
            if "bar-" in a["src"] or "search-" in a["src"]:
                self.assertGreater(len(a["alt"]), 30)

    def test_landmarks_and_scroll_regions_are_labelled(self):
        for a in self.page.of("nav"):
            self.assertTrue(a.get("aria-label") or a.get("aria-labelledby"))
        for tag, a in self.page.tags:
            if a.get("role") == "region":
                self.assertTrue(a.get("aria-label") or a.get("aria-labelledby"))
                self.assertEqual(a.get("tabindex"), "0")
        for a in self.page.of("th"):
            self.assertIn(a.get("scope"), ("col", "row"))

    def test_disclosures_are_native_and_balanced(self):
        raw = INDEX.read_text(encoding="utf-8")
        self.assertGreaterEqual(len(self.page.of("details")), 8)
        self.assertEqual(len(self.page.of("details")), len(self.page.of("summary")))
        self.assertEqual(raw.count("<details"), raw.count("</details>"))
        self.assertNotIn("role=\"button\"", section("all-features"))

    def test_visible_focus_and_reduced_motion_paths_are_present(self):
        sheet = strip_comments(css())
        self.assertIn(":focus-visible", sheet)
        self.assertRegex(sheet, r"prefers-reduced-motion\s*:\s*reduce")
        self.assertIn(".demo-search:focus-within", sheet,
                      "the demo input resets its own ring, so its container must show focus")
        for selector, block in re.findall(r"([^{}]+)\{([^{}]*)\}", sheet):
            if re.search(r"outline\s*:\s*(?:none|0)(?:[;}]|$)", block):
                self.assertIn(".demo-search input", selector,
                              "a control lost focus with no replacement ring: " + selector)

    def test_a_responsive_viewport_and_narrow_layout_exist(self):
        viewport = [a for a in self.page.of("meta") if a.get("name") == "viewport"]
        self.assertEqual(len(viewport), 1)
        self.assertIn("width=device-width", viewport[0]["content"])
        widths = [float(n) * (16 if unit == "rem" else 1)
                  for n, unit in re.findall(r"max-width\s*:\s*([\d.]+)(px|rem)\s*\)", css())]
        self.assertTrue(any(320 <= n <= 480 for n in widths))

    def test_the_decorative_ruler_is_hidden_from_assistive_technology(self):
        raw = section("funding")
        for cls in ("ruler-trough", "ruler-scale"):
            element = re.search(r'<div class="' + cls + r'"([^>]*)>', raw)
            self.assertIsNotNone(element)
            self.assertIn('aria-hidden="true"', element.group(1))


class SelectedFlowContracts(unittest.TestCase):
    def setUp(self):
        self.raw = INDEX.read_text(encoding="utf-8")
        self.text = visible(self.raw)

    def test_product_use_and_download_precede_the_research_story(self):
        for before, after in (("top", "features"), ("features", "pro"),
                              ("pro", "all-features"), ("all-features", "research")):
            self.assertLess(self.raw.index('id="%s"' % before), self.raw.index('id="%s"' % after))
        text = visible(hero())
        for phrase in ("last thing you copied", "history of text, links and images", "paste it again",
                       "search stays on your mac", "no clipboard uploads"):
            self.assertIn(phrase, text)

    def test_release_install_and_source_routes_are_kept(self):
        raw, text = hero(), visible(hero())
        self.assertIn("https://github.com/AntreasAntoniou/cliphoard/releases/download/"
                      "v1.0.2/Cliphoard-1.0.2.dmg", raw)
        self.assertIn("https://github.com/AntreasAntoniou/cliphoard/releases/tag/v1.0.2", raw)
        for phrase in ("macos 13+", "apple silicon & intel", "signed and notarized",
                       "drag cliphoard to applications", "release notes and checksum",
                       "build from source", "mit open source"):
            self.assertIn(phrase, text)
        self.assertIn("brew install --cask antreasantoniou/tap/cliphoard", text)
        self.assertIn("coming soon", text)
        self.assertIn("not yet available", text)

    def test_find_uses_the_registered_cliphoard_shortcut(self):
        flow = next(item for item in re.findall(r'<li>.*?</li>', hero(), re.S)
                    if '<h2>Find</h2>' in item)
        self.assertIn("⌃⌥⌘V", flow)
        self.assertIn('aria-label="Control Option Command V"', flow)
        shortcut = (REPO / "Sources/Cliphoard/App/AppDelegate.swift").read_text(encoding="utf-8")
        # Read the registration, not a documentation comment or the shortcut label.
        registration = re.search(r"hotKey\.register\(keyCode:\s*UInt32\((\w+)\),"
                                 r"\s*modifiers:\s*UInt32\(([^)]+)\)\)", shortcut)
        self.assertIsNotNone(registration, "the global shortcut registration changed")
        self.assertEqual(registration.group(1), "kVK_ANSI_V")
        self.assertEqual({part.strip() for part in registration.group(2).split("|")},
                         {"controlKey", "optionKey", "cmdKey"})

    def test_existing_public_anchors_and_local_legal_pages_survive(self):
        ids = parse().ids
        for anchor in ("pro", "funding", "research", "privacy"):
            self.assertIn(anchor, ids)
        links = [a.get("href") for a in parse().of("a")]
        for target in ("privacy.html", "support.html"):
            self.assertIn(target, links)
        self.assertNotIn("All website directions", self.raw)

    def test_the_complete_feature_menu_stays_thirty_items_with_three_pro_tools(self):
        menu = section("all-features")
        c = Collector(); c.feed(menu)
        self.assertEqual(len(c.of("dt")), 30)
        groups = [a for a in c.of("details") if a.get("class") == "feature-group"]
        self.assertEqual(len(groups), 6)
        pro = section("feature-visual")
        pro_c = Collector(); pro_c.feed(pro)
        self.assertEqual(len(pro_c.of("dt")), 3)
        self.assertIn('class="feature-tier">Pro', pro)
        self.assertIn("except the optional pro image tools", visible(menu))

    def test_the_real_screenshot_remains_inspectable_and_the_demo_is_labelled(self):
        figure = re.search(r'<figure[^>]*>.*?</figure>', self.raw, re.S).group(0)
        self.assertIn('src="img/bar-oneDark.png"', figure)
        self.assertIn('href="img/bar-oneDark.png"', figure)
        self.assertIn("actual app", visible(figure))
        self.assertIn("sample preview", visible(section("preview")))

    def test_research_is_first_person_and_has_no_promised_outcome(self):
        research = section("research")
        text = visible(research)
        for phrase in ("i’m antreas", "i built cliphoard", "independent", "high-risk, high-reward",
                       "ai research", "i can’t promise which experiments will work"):
            self.assertIn(phrase, text)
        self.assertNotIn("axiotic", text)
        self.assertIn('href="https://antreas.io/daedalus/">Explore my research agenda</a>',
                      research)
        for overclaim in ("our team", "we trained", "will solve", "guaranteed outcome",
                          "cliphoard is a meta-learning", "meta-learning search"):
            self.assertNotIn(overclaim, text)
        self.assertIsNone(re.search(r"\d+\s*%\s*(?:of|to|for)\b", text))


class PurchaseAndSupport(unittest.TestCase):
    def test_both_pro_routes_are_explicitly_unavailable_and_separate(self):
        text = visible(section("pro"))
        for phrase in ("pro purchasing is being prepared", "one-time purchase", "no subscription",
                       "direct download · £10 including tax", "stripe", "licence key by email",
                       "settings → cliphoard pro", "verify", "checkout coming soon",
                       "app store release coming soon", "restore purchases",
                       "direct licence keys and app store purchases are separate"):
            self.assertIn(phrase, text)
        self.assertIn("free is available to download today", text)

    def test_no_live_purchase_link_or_store_badge_is_offered(self):
        raw = INDEX.read_text(encoding="utf-8").lower()
        for needle in ("lemonsqueezy", "lemon-squeezy.com", "buy.stripe", "checkout.stripe.com",
                       "purchase.cliphoard.dev", "purchase-test.cliphoard.dev", "paddle.com",
                       "apps.apple.com", "itunes.apple.com", "app-store-badge", "gumroad", "paypal"):
            self.assertNotIn(needle, raw)

    def test_optional_personal_support_has_the_two_authorized_github_destinations(self):
        support = section("support")
        c = Collector(); c.feed(support)
        self.assertEqual([a.get("href") for a in c.of("a")], [
            "https://github.com/sponsors/AntreasAntoniou?frequency=one-time",
            "https://github.com/sponsors/AntreasAntoniou?frequency=recurring",
        ])
        self.assertIn("choose your amount on github", visible(support))
        self.assertIn("optional support, separate from pro and the software-sales goal", visible(support))
        funding = section("funding")
        self.assertNotIn("github.com/sponsors", funding)
        self.assertIn("excluded from this software-sales goal", visible(funding))


class CodeBackedClaims(unittest.TestCase):
    def setUp(self):
        self.text = visible(INDEX.read_text(encoding="utf-8"))

    def test_the_image_tools_are_pro_in_the_code_and_the_page(self):
        deep = (REPO / "Sources/Cliphoard/Search/DeepSearch.swift").read_text(encoding="utf-8")
        self.assertIn("allCases.filter { !$0.usesImageModel || entitlement.isPro }", deep)
        store = (REPO / "Sources/Cliphoard/Clipboard/ClipStore.swift").read_text(encoding="utf-8")
        self.assertIn("entitlement.isPro && imageUnderstandingEnabled", store)
        pro = visible(section("feature-visual"))
        for phrase in ("optional image tools", "pro", "find pictures by description",
                       "read text inside screenshots", "find visually similar clips"):
            self.assertIn(phrase, pro)

    def test_export_is_free_and_loss_of_its_passphrase_is_explained(self):
        gate = (REPO / "Sources/Cliphoard/Support/ProGate.swift").read_text(encoding="utf-8")
        self.assertIn("static var allowsHistoryArchive: Bool { true }", gate)
        text = visible(section("feature-move"))
        for phrase in ("passphrase-protected archive", "both directions are included in free",
                       "no recovery or escrowed key", "passphrase safe"):
            self.assertIn(phrase, text)

    def test_unlimited_history_is_an_option_and_the_initial_limit_is_known(self):
        self.assertIn("start with 200 clips, choose another limit or turn the limit off", self.text)
        self.assertIn("pinned clips are never trimmed", self.text)
        for wrong in ("unlimited history by default", "unlimited by default", "no limit by default"):
            self.assertNotIn(wrong, self.text)

    def test_only_three_importers_are_described_as_verified(self):
        source = (REPO / "Sources/Cliphoard/Support/ClipImporters.swift").read_text(encoding="utf-8")
        self.assertEqual(source.count("confidence: .verified"), 3)
        self.assertIn("paste, maccy and flycut have been verified against real installations", self.text)
        self.assertIn("alfred uses its published schema", self.text)
        self.assertIn("six other catalogued managers do not yet have adapters", self.text)

    def test_privacy_promises_keep_their_limits(self):
        for phrase in ("no cliphoard account, telemetry or automatic cloud sync",
                       "source-app names and search indexes", "timestamps, clip kind and pin state remain readable",
                       "sensitive-content filters are imperfect", "recognition and secret detection are imperfect",
                       "cannot protect an unlocked or compromised mac", "no touch id prompt is required",
                       "quarantined clips remain visible and pastable"):
            self.assertIn(phrase, self.text)
        for wrong in ("zero network calls", "no network calls", "nothing is stored in plaintext",
                      "key that cannot leave it"):
            self.assertNotIn(wrong, self.text)
        self.assertIn("selected model downloads and purchase/restore services may use the network", self.text)
        self.assertIn("those connections do not carry your clipboard content", self.text)

    def test_model_licences_are_not_conflated_with_the_application_licence(self):
        for phrase in ("open-ogma-micro", "open-ogma-small", "all-minilm-l6-v2",
                       "each model keeps its own licence and credit", "models have their own licences",
                       "entire application codebase, including pro, is mit licensed"):
            self.assertIn(phrase, self.text)
        for wrong in ("mit all the way down", "all models are mit licensed"):
            self.assertNotIn(wrong, self.text)

    def test_no_gatekeeper_workaround_is_suggested(self):
        for instruction in ("xattr", "com.apple.quarantine", "spctl", "--master-disable",
                            "open anyway", "allow anyway", "sudo ", "right-click and open", "gatekeeper off"):
            self.assertNotIn(instruction, self.text)

    def test_no_unverified_biography_performance_or_private_details(self):
        for claim in ("app i use most", "started as an irritation", "i use it every day",
                      "scratch my own itch", "instantaneous", "zero latency", "blazing",
                      "every build behaves as free", "licence server", "ed25519", "run a probe"):
            self.assertNotIn(claim, self.text)
        raw = INDEX.read_text(encoding="utf-8")
        for private in ("my-archivum", "forge/repos", "/Users/", "Documents/ChatGPT",
                        "agent-sync", "questlog", "bitwarden", "74M96PGT6P", ".p12"):
            self.assertNotIn(private, raw)


class TheNetExplanation(unittest.TestCase):
    def setUp(self):
        self.text = visible(section("funding"))

    def test_the_basis_and_currency_are_explicit(self):
        for phrase in ("how the total is counted", "provider-reported net sales proceeds",
                       "after customer taxes", "platform and payment fees", "refunds", "chargebacks",
                       "reported adjustments", "before income tax and running costs", "in us dollars",
                       "not a current bank balance", "unavailable does not mean zero"):
            self.assertIn(phrase, self.text)
        for vague in ("net revenue", "net earnings", "net income", "net receipts", "turnover"):
            self.assertNotIn(vague, self.text)

    def test_monthly_reconciliation_is_not_a_live_sales_claim(self):
        for phrase in ("reconciliation is monthly", "rather than as a live stream", "refunds can take it down"):
            self.assertIn(phrase, self.text)
        for wrong in ("live total", "updates live", "in real time", "as it happens", "live counter"):
            self.assertNotIn(wrong, self.text)

    def test_the_goal_is_a_milestone_and_buying_software_is_distinct_from_support(self):
        for phrase in ("us$250,000", "milestone, not a cap", "proceeds beyond it",
                       "buying cliphoard buys the software", "optional personal support", "is excluded"):
            self.assertIn(phrase, self.text)


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
        for cid in ("app_store", "stripe_managed_payments"):
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

    def test_the_metadata_does_not_claim_present_trade_or_reconciled_sales(self):
        metas = [a.get("content", "") for a in parse().of("meta")
                 if a.get("name") == "description" or a.get("property") == "og:description"]
        self.assertEqual(len(metas), 2)
        for content in metas:
            for wrong in ["buying it funds", "buy now", "on sale", "funds raised",
                          "we have raised", "customers"]:
                self.assertNotIn(wrong, content.lower(), "metadata asserts trade: %s" % wrong)


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
                         DOCS / "assets" / "funding.js",
                         DOCS / "assets" / "appearance.js"):
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


class HarnessAppearanceControls(unittest.TestCase):
    """Root inspects both themes in Chrome, so the harness has to be able to reach the
    state and report it. These controls exist for that and only for that."""

    def setUp(self):
        self.raw = HARNESS.read_text(encoding="utf-8")

    def test_the_three_choices_are_offered(self):
        self.assertEqual(re.findall(r'data-appearance="(\w+)"', self.raw),
                         ["system", "light", "dark"])

    def test_it_presses_the_shipped_control_rather_than_setting_the_attribute(self):
        """The point of driving the real <select> is that the shipped change handler
        and its write to storage are what get exercised. Setting `data-theme` from the
        harness would test the stylesheet and nothing else."""
        self.assertIn('field.value = button.dataset.appearance', self.raw)
        self.assertIn('dispatchEvent(new Event("change"', self.raw)
        self.assertNotIn('setAttribute("data-theme"', self.raw,
                         "the harness sets the override itself and tests nothing")

    def test_the_readback_reports_every_part_of_the_state(self):
        for token in ["data-appearance", "data-theme", "resolved", "OS prefers",
                      "stored", "(absent = System)", "HIDDEN (no JS?)"]:
            self.assertIn(token, self.raw, "the readback omits %s" % token)

    def test_it_says_how_to_reach_the_states_it_cannot_drive_itself(self):
        prose = self.raw
        self.assertIn("System Settings", prose,
                      "nothing tells the reviewer where the OS preference lives")
        self.assertIn("Site settings", prose,
                      "nothing tells the reviewer how to deny storage")

    def test_the_fixture_flags_still_cannot_reach_the_published_site(self):
        """The harness reads the framed page's storage; the SITE must not grow a flag.

        `data-appearance` lives in the harness only — docs/ never reads a query
        parameter, and the site's own attributes are written by the page itself.
        """
        self.assertNotIn("data-appearance=", INDEX.read_text(encoding="utf-8"))
        for flag in ("location.search", "URLSearchParams"):
            self.assertNotIn(flag, appearance_js())


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


class AppearanceAndPalette(unittest.TestCase):
    def test_the_two_dark_paths_and_all_palette_roles_agree(self):
        self.assertEqual(palette("system-dark"), palette("chosen-dark"))
        self.assertEqual(palette("chosen-dark")["color-scheme"], "dark")
        self.assertEqual(set(colours("light")), set(colours("chosen-dark")))
        self.assertEqual(colours("light")["--bg"], "#edf2f7")
        self.assertEqual(colours("chosen-dark")["--bg"], "#1c2028")

    def test_text_and_buttons_have_sufficient_contrast_in_both_themes(self):
        for theme in ("light", "chosen-dark"):
            tokens = colours(theme)
            for foreground in ("--text", "--muted", "--accent"):
                for surface in ("--bg", "--surface", "--surface-2"):
                    self.assertGreaterEqual(contrast(tokens[foreground], tokens[surface]), 4.5,
                                            "%s: %s on %s" % (theme, foreground, surface))
            self.assertGreaterEqual(contrast(tokens["--accent-ink"], tokens["--accent"]), 4.5)
            self.assertGreaterEqual(contrast(tokens["--accent"], tokens["--line"]), 3.0)

    def test_the_control_is_labelled_native_and_hidden_until_usable(self):
        raw = section("appearance-control")
        c = Collector(); c.feed(raw)
        self.assertEqual([a.get("for") for a in c.of("label")], ["appearance"])
        self.assertIn("appearance", visible(raw))
        self.assertEqual([a.get("id") for a in c.of("select")], ["appearance"])
        self.assertEqual(re.findall(r'<option value="(\w+)">([^<]+)</option>', raw),
                         [("system", "System"), ("light", "Light"), ("dark", "Dark")])
        self.assertIn("hidden", c.tags[0][1])
        self.assertRegex(css(), r"\[hidden\]\s*\{\s*display\s*:\s*none\s*!important")
        self.assertIn('removeAttribute("hidden")', appearance_js())

    def test_the_appearance_boundary_remains_visible_in_both_themes(self):
        rule = declarations(css_block(css(), r"\.f-appearance select\s*\{"))
        border = re.search(r"var\((--[\w-]+)\)", rule["border"]).group(1)
        for theme in ("light", "chosen-dark"):
            tokens = colours(theme)
            self.assertGreaterEqual(contrast(tokens[border], tokens["--surface"]), 3.0,
                                    "%s: appearance control border is indistinct" % theme)

    def test_system_needs_no_javascript_and_explicit_light_excludes_os_dark(self):
        sheet = (DOCS / "assets/flow.css").read_text(encoding="utf-8")
        media = css_block(sheet, r"@media\s*\(prefers-color-scheme\s*:\s*dark\)\s*\{")
        self.assertRegex(media, r':root:not\(\[data-theme="light"\]\)\s*\{')
        self.assertIn('removeAttribute("data-theme")', appearance_js())
        self.assertNotIn('data-theme=', re.search(r"<html[^>]*>", INDEX.read_text()).group(0))

    def test_browser_chrome_defaults_match_each_pages_actual_palette(self):
        main = {a.get("data-scheme"): a.get("content", "").lower()
                for a in parse().of("meta") if a.get("name") == "theme-color"}
        self.assertEqual(main, {"light": colours("light")["--bg"].lower(),
                                "dark": colours("chosen-dark")["--bg"].lower()})
        for filename in ("privacy.html", "support.html"):
            page = parse(DOCS / filename)
            metas = {a.get("data-scheme"): a.get("content", "").lower()
                     for a in page.of("meta") if a.get("name") == "theme-color"}
            self.assertEqual(metas, {"light": "#f5f5f5", "dark": "#21252b"})
            self.assertTrue(any(a.get("href", "").startswith("assets/site.css")
                                for a in page.of("link")))
            self.assertTrue(any(a.get("src") == "assets/appearance.js" for a in page.of("script")))

    def test_print_is_readable_and_overrides_each_matching_dark_screen_rule(self):
        sheet = (DOCS / "assets/flow.css").read_text(encoding="utf-8")
        printed = css_block(sheet, r"@media\s+print\s*\{")
        selectors = [s.strip() for s in printed.partition("{")[0].split(",")]
        values = declarations(css_block(printed, r":root[^{}]*\{"))
        self.assertEqual(values["color-scheme"], "light")
        self.assertGreaterEqual(contrast(values["--text"], values["--bg"]), 4.5)
        self.assertGreater(relative_luminance(values["--bg"]), .9)
        screen = [(":root", False), (':root[data-theme="dark"]', False),
                  (':root:not([data-theme="light"])', True)]
        for data_theme, dark_os in ((None, True), (None, False), ("dark", False), ("light", True)):
            applying = [s for s, needs_dark in screen
                        if root_matches(s, data_theme) and (dark_os or not needs_dark)]
            winners = [s for s in selectors if root_matches(s, data_theme)]
            for screen_selector in applying:
                self.assertTrue(any(specificity(p) >= specificity(screen_selector) for p in winners),
                                "print loses to %s with %s / dark OS %s" % (screen_selector, data_theme, dark_os))
        self.assertTrue(set(colours("light")) <= set(values), "print leaves a colour at its screen value")


class ClaimMirror(unittest.TestCase):
    """The current webpage promises also covered by DocsLaunchClaimTests.swift."""
    def test_source_app_encryption_and_passphrase_security_still_have_visible_sentences(self):
        text = visible(INDEX.read_text(encoding="utf-8"))
        for anchor in ("aes-gcm protects stored content, images, thumbnails, source-app names and search indexes",
                       "encrypted export uses aes-256-gcm", "key derived from your passphrase",
                       "pbkdf2-hmac-sha256", "at least 600,000 iterations",
                       "the passphrase is the only key", "there is no recovery or escrow"):
            self.assertIn(anchor, text)

    def test_retired_sync_and_export_claims_stay_retired(self):
        text = visible(INDEX.read_text(encoding="utf-8"))
        for stale in ("point the store", "synced folder", "never stored in the first place",
                      "you get nothing", "skipped automatically", "encrypted export/import is planned",
                      "there is no export or import", "there is no export yet",
                      "export/import is planned for 1.0.1"):
            self.assertNotIn(stale, text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
