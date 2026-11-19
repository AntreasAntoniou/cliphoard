# Beta check — approximately 15 minutes

Use harmless generated content and a normal, non-administrator Notepad window. Record pass/fail/skipped and the steps for any failure. Leave passwords and real confidential clips out of testing.

| Check | Expected result |
| --- | --- |
| Install, launch, close and reopen from Start | One app instance; bottom pane opens and responds |
| Copy two different sentences, then copy the first again | Entries appear; the duplicate moves up without multiplying |
| Copy `café — 日本語 — مرحبا — 🐱` and multiline text | Text remains intact on preview and paste |
| Search an exact word, clear it, then search an absent string | Expected matches, complete history after clearing, empty absent result |
| Select with arrows, Enter to paste, Escape to dismiss | Correct selected text goes to the original Notepad window; Escape does not paste |
| Ctrl+C on a selected card | Copies that card without an automatic paste |
| Close and reopen the pane five times; switch to another app and back | Content stays current; focus and selection remain usable |
| Pin a clip, quit normally and relaunch | Clip and pin persist |
| Copy a large image containing fine text or stripes | Sharp card preview; Inspect is sharper at its larger size; no unexplained crop |
| Copy a small image, a portrait image and a transparent PNG | Correct aspect ratio and transparency; source resolution is not invented |
| Change light/dark appearance and preview a different layout | Teal logo stays transparent, controls readable, pane remains at the bottom |
| Choose two copy sounds, use Preview sound, enable copy sound and copy text | Chosen cues play; selection survives a normal relaunch; disabling sounds stays quiet |
| Prepare an optional text/image model explicitly; search a related topic | Readiness is visible; record relevance and latency, including irrelevant results |
| Pause capture, copy a new harmless sentence, resume | Paused copy is not ingested retroactively |
| Normally lock and unlock your own session, if convenient | Hidden content does not spontaneously reopen on unlock; reopening remains usable |
| Optional: fresh installation and normal uninstall on a disposable test profile | Per-user install succeeds; normal uninstall leaves history intact |

For multiple monitors or scaling other than 100%, record which display the pointer is on when summoning, its scale, and whether image and panel edges remain correct. On physical Intel/AMD Windows devices, explicitly identify that environment; those results extend the existing emulation coverage.

Do not automate sign-in, input blocking or elevated-target bypasses. Report any unexpected insertion or stuck modifier immediately with synthetic reproduction steps.
