# WeUI KPW4 full-function test matrix

Target profile: Kindle Paperwhite 4, 1072 x 1448 portrait, 300 DPI, grayscale,
touch input, constrained-memory/e-ink refresh assumptions.

| Area | Runtime coverage | Deterministic coverage | Acceptance criteria |
| --- | --- | --- | --- |
| Install/startup | Fresh isolated data directory; one embedded plugin | Package layout test | No duplicate plugin, crash, migration prompt, or missing dependency |
| Home | Default page and content modules | Lua parse/load checks | No clipping, overlap, missing icon, or unreadable text |
| Bottom/top bars | Home, library, WeRead, Z-Library, settings, reader | Layout structural test | Consistent icon size/style; active state correct; tap targets suitable for PW4 |
| Library | Root, nested directory, mixed filenames | Runtime navigation | Rows and metadata fit; back/navigation remain available |
| Private books | Mark, mask in library, explicit lock state | Privacy API and placeholder assertions | Real title/author are not exposed while locked |
| Settings/customization | Root plus home, bars, library, style, layout, about | On-disk settings round-trip | Every page renders; version/author are present; changes persist |
| Onboarding | Welcome, presets, tips | Fresh-install state | First-run flow fits the screen and can finish without trapping the user |
| Recent/history | Recent modal with sample history | Empty/non-empty paths | Private content remains masked; modal fits between bars |
| WeRead | Logged-out main menu and offline manager | Progress-sync test | Login path visible; download/library functions are clearly separated |
| Z-Library | Cached browse, Chinese language picker, account dialog, rich book details | Mirror failover, proxy, UI adapter, download resilience | Bottom bar retained; credentials reachable; Chinese labels complete; bounded failover does not replay streams or bypass proxy protection; errors are actionable |
| Reader | Open TXT document, reader-ready lifecycle | Progress-sync test | Book opens, UI remains responsive, return to library works |
| Sleep screen | Configured message, box style and vertical position | Settings assertions and suspend/resume log audit | Full-screen grayscale output; custom content is retained; resume does not duplicate bars or lose state |
| Updater | Check, network gate, download and archive policy | Three updater tests plus live release lookup | Connected Wi-Fi is recognized; fallbacks work; unsafe URLs/archives are rejected; single package only |
| Rotation/regression | Portrait baseline; landscape code paths statically parsed | Full Lua syntax pass | Portrait output is stable; no stale dimension cache errors |
| Reliability | Startup/feature log scan | Fault injection and retry tests | No traceback, panic, uncaught error, unsafe URL/credential logging |
