# WeUI KPW4 full-function test matrix

Target profile: Kindle Paperwhite 4, 1072 x 1448 portrait, 300 DPI, grayscale,
touch input, constrained-memory/e-ink refresh assumptions.

| Area | Runtime coverage | Deterministic coverage | Acceptance criteria |
| --- | --- | --- | --- |
| Install/startup | Fresh isolated data directory; one embedded plugin | Package layout test | No duplicate plugin, crash, migration prompt, or missing dependency |
| Home | Default page and content modules | Lua parse/load checks | No clipping, overlap, missing icon, or unreadable text |
| Bottom/top bars | Home, library, WeRead, Z-Library, settings, reader | Layout structural test | Consistent icon size/style; active state correct; tap targets suitable for PW4 |
| Library | Root, nested directory, mixed filenames | Runtime navigation | Rows and metadata fit; back/navigation remain available |
| Private books | Mark, mask in library, lock state | Privacy API assertions | Real title/author are not exposed while locked |
| Settings/customization | Root plus home, bars, library, style, layout, about | Settings persistence audit | Every page renders and changes remain isolated/persistent |
| Onboarding | Welcome, presets, tips | Fresh-install state | First-run flow fits the screen and can finish without trapping the user |
| Recent/history | Recent modal with sample history | Empty/non-empty paths | Private content remains masked; modal fits between bars |
| WeRead | Logged-out main menu and offline manager | Progress-sync test | Login path visible; download/library functions are clearly separated |
| Z-Library | Cached browse, account dialog, rich book details | Proxy, UI adapter, download resilience | Bottom bar retained; credentials reachable; no direct connection when proxy protection applies; errors are actionable |
| Reader | Open TXT document, reader-ready lifecycle | Progress-sync test | Book opens, UI remains responsive, return to library works |
| Sleep screen | Message/image-capable screensaver preview | Suspend/resume log audit | Full-screen grayscale output; resume does not duplicate bars or lose state |
| Updater | Check, network gate, download | Three updater tests | Connected Wi-Fi is recognized; timeout/protocol errors are distinguished; single package only |
| Rotation/regression | Portrait baseline; landscape code paths statically parsed | Full Lua syntax pass | Portrait output is stable; no stale dimension cache errors |
| Reliability | Startup/feature log scan | Fault injection and retry tests | No traceback, panic, uncaught error, unsafe URL/credential logging |
