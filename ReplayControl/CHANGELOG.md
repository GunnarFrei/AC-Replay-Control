# 0.1.38

- Replaced accumulated development notes with one current English guide.
- Removed outdated diagnostic verification, unused timing state, old SVG drafts
  and the message referring to removed fallback controls.
- Corrected frame stepping from fast, reverse and slow playback: first return
  to 1x, then pause if necessary, then apply the requested recorded-frame step.
- Scrubbing cancels any older queued playback command and releases owned keys.
- A different replay filename invalidates old lap markers even if length matches.
- Improved timeline-marker alignment for the narrower playback handle.
- Kept button captions readable at the smallest configured button size.
- Added readable Numpad, arrow and function-key names to the binding overview.
- Reset appearance also resets the header selection and fits window height.
- Added a Lua 5.1 behavioral test harness outside the distributed app folder.
