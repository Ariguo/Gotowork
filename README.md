# Gotowork

Local macOS foreground-window recorder. It records local JSONL first, then lets the user manually confirm generated blocks before writing them to Apple Calendar.

The native app bundle is `Gotowork.app`; the command-line recorder binary is `foreground-tracker`.

## Build

```bash
make build
make app
```

Build artifacts and local activity data are intentionally ignored by Git.

The app bundle is created at:

```bash
dist/Gotowork.app
```

It is a menu bar app. When launched, it starts recording automatically and writes raw JSONL under:

```bash
~/Library/Application Support/Gotowork/
```

The command-line recorder uses the same Gotowork app data directory by default, so local app and CLI runs share one raw data source.

Click `FT Rec` in the menu bar to open the native Chinese dashboard popover. It shows a three-column Apple Calendar-style view with date/project filters, app ranking, a central timeline, hover/selection details, pending calendar candidates, and quick controls for pause/resume, data folder, accessibility permission, and quit.

## Dashboard Preview Regression

The native dashboard can render deterministic PNG previews without opening the menu bar UI:

```bash
make previews
```

By default this writes a visual matrix to:

```bash
/tmp/foreground-tracker-previews/
```

The preview set covers normal light/dark layouts, 900px narrow layouts, pending-calendar popover, hover details, manual creation, confirmed calendar state, and the write-success flash. You can override the fixture date, clock, or output folder:

```bash
make previews PREVIEW_DATE=2026-05-28 PREVIEW_NOW=16:20 PREVIEW_DIR=/tmp/ft-previews
```

Individual previews use the app binary directly:

```bash
dist/Gotowork.app/Contents/MacOS/ForegroundTracker --render-dashboard-preview /tmp/ft.png --date 2026-05-28 --now 16:20 --preview-size 900x680
dist/Gotowork.app/Contents/MacOS/ForegroundTracker --render-dashboard-preview /tmp/ft-confirmed.png --date 2026-05-28 --select-first-calendar --confirm-first-calendar --flash-first-calendar
```

## Check Permissions And Current Window

```bash
.build/debug/foreground-tracker sample
```

If `accessibility_trusted=false`, approve the built binary in:

System Settings > Privacy & Security > Accessibility

Then run the command again.

## Record

```bash
.build/debug/foreground-tracker record --poll 5 --idle 120 --reconcile 60
```

The recorder uses:

- App activation notifications for fast app switch detection.
- Accessibility focus notifications for front-window changes.
- A 5 second idle poll to pause after 2 minutes with no keyboard/mouse input.
- A 60 second reconcile poll to recover from missed AX notifications.

Raw segments are appended only when a segment closes. App switches that last `<=1s` are ignored and do not enter the raw file or dashboard rollups.

Browser apps are recorded at app level only. URL/title changes in Safari, Chrome, Edge, Firefox, Brave, Arc, Vivaldi, and Opera do not create separate raw segments.

## Preview Calendar-Like Blocks

```bash
.build/debug/foreground-tracker report --day 2026-05-22
```

Defaults:

- Each minute is assigned to its dominant app/window when that winner has at least `40s` active time or at least `60%` of observed activity in that minute.
- A sliding 3 minute raw-data rollup then smooths noisy gaps: when one app has at least `120s` active time inside any 3 minute window, those minutes are assigned to that app.
- Consecutive assigned minutes for the same app/window are merged.
- Merged blocks shorter than `180s` wall-clock duration are filtered out.
- Merge key: app-level. Use `--key window` to require the same non-browser window title.
- Browser URL/title values are ignored in both raw recording and report preview.

Useful filters:

```bash
.build/debug/foreground-tracker report --contains 飞书
.build/debug/foreground-tracker report --bundle com.example.App
.build/debug/foreground-tracker report --minute-min-ratio 0.7
.build/debug/foreground-tracker report --minute-min-active 45
.build/debug/foreground-tracker report --rollup-window 3 --rollup-min-active 120
.build/debug/foreground-tracker report --min-duration 180
.build/debug/foreground-tracker report --json
```
