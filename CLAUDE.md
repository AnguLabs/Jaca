# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Jaca is a non-sandboxed SwiftUI macOS app (developer tools): device log streaming, network capture (in-process Android agent + MITM proxy), and local maintenance areas (Projects — auto-detected Claude projects + their worktrees + user-added folders, with per-checkout cache cleanup; Gradle daemons; Xcode DerivedData). See `README.md` for the product/network-capture deep dive.

## Build, run, test

The Xcode project is **not committed** — it's generated from `project.yml` by XcodeGen. Source files are globbed from `Sources/` (and `Tests/`, `UITests/`), so **adding a file needs no `project.yml` change** — just regenerate. `Jaca.xcodeproj/` is gitignored.

```bash
./scripts/run.sh            # generate + build (Debug) + launch
./scripts/build.sh [Release]# build only
./scripts/gen.sh            # regenerate Jaca.xcodeproj from project.yml
./scripts/uitest.sh         # XCUITest suite (kills stray instances first)
./scripts/all.sh [--release|--install|--no-agent|--no-run]  # agent + app + launch
```

The scripts set `DEVELOPER_DIR` to Xcode (needed when `xcode-select` points at the CLT). To run **one test** (scripts don't expose this), invoke xcodebuild directly:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Jaca.xcodeproj -scheme Jaca -configuration Debug -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  -only-testing:JacaTests/ClaudeProjectGroupingTests/test_group_nestsWorktreesUnderTheirParentRepo test
```

`JacaTests` includes **live** tests (`LiveAndroidTests`, `LiveSimulatorTests`, `LiveAgentCaptureTests`) that need a real device/emulator/agent and **fail** when absent — skip them with `-skip-testing:JacaTests/LiveAgentCaptureTests` etc. when verifying logic locally.

### Building from a `.claude/worktrees/` worktree

`project.yml` declares Lemonade as `path: ../lemonade-design-system`, resolved from the repo root. That works from the main checkout but **not** from a worktree two levels down — XcodeGen fails with *"Invalid local package Lemonade"*. To build in-worktree, symlink it first, then remove it after (the built `.app` is self-contained; the link is only needed at build time):

```bash
ln -sf "$HOME/workspace/lemonade-design-system" "$(git rev-parse --show-toplevel)/../lemonade-design-system"
```

## Architecture

Three layers, enforced by directory:

- **`Sources/Core/`** — no SwiftUI. Device discovery, log sources, SQLite history, the proxy, the agent controller, and the per-area services (git, Gradle, DerivedData, Claude scanning). New backends slot in behind small protocols (`DeviceProvider`, `LogSource`).
- **`Sources/Model/`** — `@Observable @MainActor` state. `AppModel` owns the device list, open tabs, and one model instance per top-level area. Session types (`LogSession`, `NetworkSession`) conform to `WorkspaceTab`.
- **`Sources/Features/`** — SwiftUI views, one folder per feature.

### The top-level "area" pattern

The left sidebar switches the main pane between **areas** via `AppModel.mode: WorkspaceMode` (`devices`, `projects`, `gradle`, `xcode`). Adding an area means touching a consistent set of files — read one existing area end-to-end (e.g. Projects or Xcode) before adding one:

1. A case in `enum WorkspaceMode` (in `AppModel.swift`) + a model instance `let foo = FooModel()` on `AppModel`.
2. A `Core/<Area>/` service (does the filesystem/process/git work, off the main actor).
3. A `Model/FooModel.swift` (`@Observable @MainActor`) holding view state and calling the service.
4. `Features/<Area>/` — a sidebar header (`onTapGesture { model.mode = .foo }`, styled like the others) and an area view.
5. Wire both into `App/RootView.swift`: add the header to the sidebar `VStack` and a branch to the `detail` switch.

Long-running work (logcat, the proxy) accumulates off the main thread and flushes into the observed model on a timer so a chatty device doesn't stutter the UI. Network capture picks **agent vs proxy** per tab (`NetworkSession`); the in-process Android agent lives under `agent/` (built separately — see README).

## Conventions

- **Design system:** build UI from Lemonade — `LemonadeUi.*` components, `LemonadeTheme.colors.*` / `LemonadeTypography.shared.*` semantic tokens, `GroveIcon(glyph:)`. Don't hardcode colors/fonts; match the tokens used in neighboring views.
- **Animate state changes:** the app aims for a polished, fluid feel — every meaningful UI state change should animate, not snap. Expand/collapse, list inserts/removes, tag/size updates, refresh indicators, hover affordances, and view-mode switches should use `withAnimation`/`.animation(_:value:)` and `.transition(...)`. Follow the established style: short `.easeInOut` (~0.15–0.3s), rows fade+slide on insert/remove (e.g. `.opacity` while `removing`, green flash on a freed size), chevrons rotate on expand. When adding UI, add the matching animation by default — keep it subtle and consistent with neighboring views rather than flashy.
- **Testability:** factor pure logic out of services/models into free functions/enums and unit-test those (e.g. `WorktreePorcelainParser`, `ProjectsGrouping`, `LogcatParser`) rather than testing through the UI.
- **Non-sandboxed by design** so the app can `Process`-spawn `adb`/`xcrun`/`git` — don't add the App Sandbox entitlement.

## Reactive-first & caching (IMPORTANT)

Areas must feel **instant**. A screen that has shown data before must **never flash empty** while it recomputes — opening it, switching away and back, or relaunching the app should all render immediately from the last known result. This is a first-class requirement, not a nice-to-have.

The pattern (reference implementation: `ProjectsModel` + `ProjectsCache`):

1. **Persist the last result to disk** (`Codable` → `~/Library/Caches/Jaca/…`), including expensive derived data like `du` sizes, on every successful scan.
2. **Load the cache synchronously in the model's `init`**, so the first frame already has data.
3. **Block only the cold first scan** (no cache to show); afterwards refresh in the **background** while the cached data stays interactive, behind a subtle "Refreshing…" indicator.
4. **Gate auto-refresh on a staleness TTL** (don't rescan on every `onAppear`) so re-entering a screen within a session is free; keep an explicit refresh control, and where it helps, a `FolderWatcher` to refresh automatically when the underlying directories change.
5. **Compute slow per-item work (e.g. `du`) in the background**, patching rows as results land, so a list with many items stays responsive instead of blocking.

When adding or revisiting an area whose data comes from the filesystem/processes (Gradle daemons and Xcode DerivedData currently rescan on appear), prefer this cache-first, background-refresh shape over scan-on-open.
