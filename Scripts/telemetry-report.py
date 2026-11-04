"""Read-only aggregate report. Python 3.14+. Pass the Cloudflare token on stdin only.

The caller obtains credentials through its approved secret broker. This script does
not inspect vaults, browser sessions, environment credentials or local secret files.
"""
import sys
if sys.version_info < (3, 14):
    raise SystemExit("Python 3.14+ required")

import argparse
from collections import Counter
from datetime import datetime, timezone
import html
import json
import math
import os
from pathlib import Path
import re
import tempfile
import urllib.error
import urllib.request

ACCOUNT = "f785b36f14fd12a5fd289bfb3a8a9daf"
DATASET = "cliphoard_metrics_v1"
REPO = "AntreasAntoniou/cliphoard"

class ReportError(Exception):
    pass

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

def read_json(url, *, token=None, data=None):
    headers = {"User-Agent": "Cliphoard-aggregate-report/1", "Accept": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    if data is not None:
        headers["Content-Type"] = "text/plain"
    req = urllib.request.Request(url, headers=headers, data=data)
    try:
        with urllib.request.build_opener(NoRedirect).open(req, timeout=25) as response:
            raw = response.read(4_000_001)
            if len(raw) > 4_000_000:
                raise ReportError("Response exceeds report limit")
            return json.loads(raw), response.headers.get("Link", "")
    except urllib.error.HTTPError as error:
        raise ReportError(f"Provider HTTP {error.code}") from None
    except ReportError:
        raise
    except Exception:
        raise ReportError("Provider response unavailable") from None

def release_rows(releases):
    rows = []
    for release in releases:
        if release.get("draft") or release.get("prerelease"):
            continue
        for asset in release.get("assets", []):
            name, count = asset.get("name", ""), asset.get("download_count")
            if not re.fullmatch(r"Cliphoard-[0-9]+\.[0-9]+\.[0-9]+\.dmg", name):
                continue
            if not isinstance(count, int) or isinstance(count, bool) or count < 0:
                raise ReportError("Invalid download count")
            rows.append({"release": str(release["tag_name"]), "asset": name,
                         "asset_id": asset["id"], "downloads": count})
    return rows

def downloads():
    releases = []
    for page in range(1, 11):
        data, links = read_json(f"https://api.github.com/repos/{REPO}/releases?per_page=100&page={page}")
        if not isinstance(data, list):
            raise ReportError("Invalid release response")
        releases.extend(data)
        if 'rel="next"' not in links:
            return {"status": "available", "releases": release_rows(releases)}
    raise ReportError("Release pagination exceeds report limit")

def event_query(days):
    if not isinstance(days, int) or not 1 <= days <= 90:
        raise ReportError("Report days must be 1 to 90")
    return f"""SELECT formatDateTime(timestamp, '%Y-%m-%d') AS day,
      blob2 AS surface, blob3 AS mode, blob4 AS event, blob5 AS placement,
      blob6 AS source, blob7 AS country, SUM(_sample_interval * double1) AS events,
      MAX(_sample_interval) AS max_sample_interval
      FROM {DATASET} WHERE blob1 = 'v1' AND timestamp >= NOW() - INTERVAL '{days}' DAY
      GROUP BY day, surface, mode, event, placement, source, country
      ORDER BY day DESC, surface, mode, event, placement, source, country LIMIT 10000 FORMAT JSON"""

def analytics(token, days):
    payload, _ = read_json(f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}/analytics_engine/sql",
                           token=token, data=event_query(days).encode())
    rows = payload.get("data")
    if not isinstance(rows, list) or len(rows) >= 10000:
        raise ReportError("Analytics result missing or truncated")
    for row in rows:
        if set(row) != {"day", "surface", "mode", "event", "placement", "source", "country", "events", "max_sample_interval"}:
            raise ReportError("Analytics schema differs")
        for key in ("events", "max_sample_interval"):
            value = float(row[key])
            if not math.isfinite(value) or value < 0 or value > 1e15:
                raise ReportError("Invalid analytics count")
            row[key] = value
    return {"status": "available", "rows": rows, "sampled": any(r["max_sample_interval"] > 1 for r in rows)}

def safe_call(fn):
    try:
        return fn()
    except ReportError as error:
        return {"status": "unavailable", "reason": str(error)}

def totals(rows, mode="live"):
    result = Counter()
    for row in rows:
        if row["mode"] == mode:
            result[(row["surface"], row["event"], row["placement"])] += row["events"]
    return result

def alerts(report):
    result = []
    if report["analytics"]["status"] != "available":
        result.append("Analytics read unavailable; do not interpret as zero activity.")
    else:
        counts = totals(report["analytics"]["rows"])
        exhausted = counts[("commerce", "email_exhausted", "order")]
        if exhausted:
            result.append(f"{exhausted:g} live email delivery runs exhausted their retries; inspect fulfilment records.")
        errors = counts[("commerce", "request_error", "webhook")]
        if errors:
            result.append(f"{errors:g} live webhook requests returned server errors; inspect provider retries.")
    if report["downloads"]["status"] != "available":
        result.append("GitHub download counts unavailable.")
    return result

def dashboard(report):
    esc = lambda value: html.escape(str(value), quote=True)
    a, d = report["analytics"], report["downloads"]
    rows = a.get("rows", []); counts = totals(rows)
    def count(surface, event):
        if a["status"] != "available":
            return "Unavailable"
        return f"{sum(v for (s, e, _), v in counts.items() if (s, e) == (surface, event)):g}"
    downloaded = str(sum(r["downloads"] for r in d.get("releases", []))) if d["status"] == "available" else "Unavailable"
    cards = [("Installer downloads", downloaded, "All public DMGs · lifetime · repeats included"),
             ("Website page views", count("website", "page_view"), "Page loads · not unique visitors"),
             ("Free download clicks", count("website", "download_click"), "Intent · not completed downloads"),
             ("Pro interest", count("website", "pro_interest"), "Navigation + purchase details · not buyers"),
             ("Direct licences issued", count("commerce", "licence_issued"), "Live mode · approximate operational count"),
             ("Email accepted", count("commerce", "email_accepted"), "Live mode · inbox arrival not established")]
    def table(headers, values):
        values = list(values)
        if not values:
            return '<p class="muted">No observations in this window. Collection starts at deployment; there is no historical backfill.</p>'
        return '<div class="scroll"><table><thead><tr>' + ''.join(f'<th>{esc(h)}</th>' for h in headers) + '</tr></thead><tbody>' + ''.join('<tr>' + ''.join(f'<td>{esc(v)}</td>' for v in row) + '</tr>' for row in values) + '</tbody></table></div>'
    daily = Counter(); ref = Counter(); countries = Counter()
    for row in rows:
        if row["mode"] == "live":
            daily[(row["day"], row["surface"], row["event"])] += row["events"]
            if row["surface"] == "website" and row["event"] == "page_view":
                ref[row["source"]] += row["events"]; countries[row["country"]] += row["events"]
    sparse = sum(n for country, n in countries.items() if n < 5)
    geography = [(country, f"{n:g}") for country, n in countries.most_common() if n >= 5]
    if sparse:
        geography.append(("Countries with fewer than 5 views (combined)", f"{sparse:g}"))
    sections = [
        ("Downloads by release", table(["Release", "Installer", "GitHub downloads"], ((r["release"], r["asset"], r["downloads"]) for r in d.get("releases", [])))),
        ("Live event breakdown", table(["Surface", "Event", "Placement", "Weighted count"], ((s, e, p, f"{v:g}") for (s, e, p), v in sorted(counts.items())))),
        ("Daily activity · UTC", table(["Day", "Surface", "Event", "Weighted count"], ((day, s, e, f"{v:g}") for (day, s, e), v in sorted(daily.items(), reverse=True)))),
        ("Where website visits came from", table(["Referral group", "Page views"], ((k, f"{v:g}") for k, v in ref.most_common()))),
        ("Country groups", table(["Country", "Page views"], geography)),
        ("Test and QA · excluded above", table(["Mode", "Surface", "Event", "Placement", "Weighted count"], ((mode, s, e, p, f"{v:g}") for mode in ("test", "qa") for (s, e, p), v in sorted(totals(rows, mode).items())))),
    ]
    warning = ''.join(f'<li>{esc(item)}</li>' for item in report["alerts"])
    return '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Cliphoard · Activity</title><style>
:root{color-scheme:light dark;--bg:#eef2f7;--card:#fff;--ink:#1b2b40;--muted:#536479;--line:#d5dfeb;--accent:#276ab1}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.6 -apple-system,BlinkMacSystemFont,sans-serif}main{max-width:1200px;margin:auto;padding:48px 24px}header{margin-bottom:28px}h1{font-size:44px;letter-spacing:-1.6px;margin:0}h2{font-size:22px;margin:0 0 18px}.eyebrow{font-size:12px;letter-spacing:2px;text-transform:uppercase;color:var(--accent)}.muted,small{color:var(--muted)}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:16px}.card,section{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:24px}.card strong{display:block;font-size:40px;letter-spacing:-1px}.card small{display:block}section{margin-top:22px}.scroll{overflow:auto}table{width:100%;border-collapse:collapse;font-size:14px}th{text-align:left;color:var(--muted);font-weight:600}th,td{padding:12px 10px;border-bottom:1px solid var(--line);white-space:nowrap}.notice{border-left:4px solid var(--accent);padding:8px 18px;margin:24px 0}code{font-size:13px}@media(prefers-color-scheme:dark){:root{--bg:#141c27;--card:#1d2937;--ink:#e7eef8;--muted:#a9bbcf;--line:#33475c;--accent:#80bafa}}
</style><main><header><p class="eyebrow">Cliphoard / private operations</p><h1>What’s happening.</h1><p class="muted">''' + esc(report["generated_at"]) + f' · Last {report["days"]} days · UTC · Snapshot, not a live connection</p></header><div class="cards">' + ''.join(f'<div class="card">{esc(title)}<strong>{esc(value)}</strong><small>{esc(note)}</small></div>' for title, value, note in cards) + '</div><div class="notice">Website events and purchase counters are approximate. Opt-outs, bots, repeat visits and provider sampling affect totals. No unique-user, installed-app or conversion-rate claim follows. Pro interest combines two placements. Current app usage is not collected. App Store downloads/sales require Apple reports and are not included. Public paid checkout remains a separate release gate.</div>' + (f'<section><h2>Needs attention</h2><ul>{warning}</ul></section>' if warning else '') + ''.join(f'<section><h2>{esc(title)}</h2>{content}</section>' for title, content in sections) + '<p class="muted">No cookies, visitor identifiers, clipboard activity or customer keys in this dashboard. Test and QA are separate. Counts use Cloudflare sampling weights; accounting requires provider reconciliation.</p></main></html>'

def write_private(path, content):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        stream.write(content)

def replace_private(path, content):
    """Publish a complete private snapshot without following an existing symlink."""
    fd, temporary = tempfile.mkstemp(prefix=".activity-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(content)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--days", type=int, default=30, choices=range(1, 91))
    parser.add_argument("--cloudflare-token-stdin", action="store_true", required=True)
    args = parser.parse_args()
    if sys.stdin.isatty():
        raise ReportError("Token must come from the approved secret consumer, not an interactive prompt")
    token = sys.stdin.readline(8193).strip()
    if not token or len(token) > 8192 or any(c.isspace() for c in token):
        raise ReportError("Invalid token input")
    report = {"generated_at": datetime.now(timezone.utc).isoformat(), "days": args.days,
              "downloads": safe_call(downloads), "analytics": safe_call(lambda: analytics(token, args.days))}
    token = None
    report["alerts"] = alerts(report)
    args.output.mkdir(parents=True, exist_ok=True, mode=0o700)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    json_path, html_path = args.output / f"activity-{stamp}.json", args.output / f"activity-{stamp}.html"
    json_text, html_text = json.dumps(report, indent=2) + "\n", dashboard(report)
    write_private(json_path, json_text)
    write_private(html_path, html_text)
    replace_private(args.output / "latest.json", json_text)
    replace_private(args.output / "latest.html", html_text)
    print(json.dumps({"json": str(json_path.resolve()), "html": str(html_path.resolve()),
                      "latest_html": str((args.output / "latest.html").resolve()),
                      "analytics": report["analytics"]["status"], "downloads": report["downloads"]["status"], "alerts": report["alerts"]}))
    return 0 if all(report[k]["status"] == "available" for k in ("analytics", "downloads")) else 2

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ReportError as error:
        print(json.dumps({"error": str(error)})); raise SystemExit(1) from None
