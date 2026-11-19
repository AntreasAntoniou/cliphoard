# Manual VM shortcut alternative — 15 November 2026

The owner reported that the V combination opened the local macOS Cliphoard instead of reaching Windows. The Windows synthetic fixture now also registers Ctrl+Alt+Shift+B (virtual key 0x42) with MOD_NOREPEAT. The existing V registration remains. Both registrations must succeed, both dispatch through the existing foreground/epoch/target guards, and both are unregistered on disposal. Host shortcuts and the local macOS app were not changed.

On a Mac keyboard, focus Windows and use **Control+Option+Shift+B**. The status line identifies the received combination.

Verification: the native Windows ARM64 frontend build passed with zero warnings/errors. Through local Parallels keyboard input, B opened the panel with deliveries=1 and foreground=True; after Escape, a one-second held B combination reopened it with deliveries=2 and foreground=True. Three generated fixture rows were visible. No WM_HOTKEY was posted as keyboard proof. The synthetic app and engine are intentionally left running for owner testing, with the panel visible.
