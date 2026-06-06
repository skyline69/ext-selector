# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ExtSelector ("Extension Selector") is a native macOS SwiftUI app for viewing and changing the **default application** that opens each file type, browsable by category. Pure Swift Package — no Xcode project, no external dependencies. Targets macOS 26.0+, Swift 6 (strict concurrency).

## Commands

```sh
swift build                 # debug build
swift build -c release      # release build
swift test                  # run all tests
swift test --filter CatalogTests/testExplicitUTIsAreValid   # single test
./bundle.sh                 # build release + wrap binary into ExtSelector.app
./bundle.sh debug           # same, debug config
open ExtSelector.app        # run the bundled app
```

`bundle.sh` exists because a bare SPM executable launches as an accessory process (no Dock icon, window won't focus). It copies the SPM binary + the `ExtSelector_ExtSelector.bundle` resource bundle into a hand-written `.app` and synthesizes `Info.plist`. `AppDelegate` additionally forces `.regular` activation policy at launch (see `App.swift`).

## Architecture

Data flows: **Catalog.json → Catalog model → SwiftUI views → HandlerStore (cache) → LaunchServicesManager (system API).**

- **`Resources/Catalog.json`** — the curated list of file types, grouped into 5 categories. Each entry is `{name, ext?, uti?}`. This is the only data source; editing the app's content = editing this file.

- **`Models/Catalog.swift`** — decodes the JSON. The key concept is `FileTypeEntry.resolution`: it maps an entry to a concrete `UTType`, preferring explicit `uti` over `ext`, and only accepts types where `isDeclared` is true (some installed app actually declares them). A failed mapping becomes `.unresolved(reason:)`, surfaced in the UI as "unmanaged" and printed as warnings in DEBUG. Decode failure is `fatalError` — the JSON ships in-bundle, so a failure is a programmer error.

- **`Services/LaunchServicesManager.swift`** — thin wrapper over Launch Services. Two ways to set a default: `setDefault` (modern `NSWorkspace` async API, triggers the macOS "Use X / Keep Y" confirmation) and `setDefaultSilently` (`LSSetDefaultRoleHandlerForContentType`, no prompt — used for bulk "Set all" where one prompt per type would be unusable). **Not sandboxed** — mutating system default handlers requires it.

- **`Services/HandlerStore.swift`** — an `actor` caching Launch Services lookups keyed by UTType identifier. Off-main-thread queries, race-free, instant revisits. Invalidation contract: invalidate the affected type after changing its default; `invalidateAll()` on app re-focus (defaults may have changed in another app).

- **`Models/AppHandler.swift`** — an installed app that can open a type. Cheap to construct (only URL + display name up front); icon is lazy + cached via `IconCache` because most candidates are never shown.

- **`Views/`** — `ContentView` is the root (search, category switching, splash warm-up, bulk "Set all", re-focus invalidation). `FileTypeRowView` owns one row's state machine (`.loading/.unknownType/.noHandlers/.ready`) and the per-type picker. `CategoryNavBar`, `Theme` (all colors live here), `CustomScrollbar` (+ `ScrollMetrics`), `LoadingView`.

### Conventions / things to preserve

- **Re-read truth after a change.** Setting a default can "fail" via throw even on success (the user picking "Keep old" surfaces as an error). Never trust the call's result — invalidate the cache and re-read the actual current default. See `FileTypeRowView.apply`.
- **State containment for scroll perf.** Scroll position/metrics live in child views (`CategoryScrollView`, `AppDropdown`) so per-frame scroll updates don't re-render the parent. Keep new per-frame state out of `ContentView`.
- **`refreshToken: Int`** is the cross-view "reload now" signal — bumping it re-runs each row's `.task(id:)`.
- Modeling: prefer one exhaustive `enum` state over loose boolean flags (the row's `State`, `Resolution`).

## Tests

`CatalogTests` validate the data, not the UI: catalog loads non-empty, every **explicit** `uti` resolves (a bad one is a typo that must fail the build — `ext`-only entries are environment-dependent and not asserted), and all `id`s are unique (they feed SwiftUI diffing). When adding catalog entries with explicit UTIs, `testExplicitUTIsAreValid` is the guard.
