# Jaca

A native macOS app for watching what your connected devices are doing — their
logs and their network traffic — in a fast, multi-tab "terminal" UI.

Point it at an Android emulator, a physical Android phone, or an iOS simulator,
pick a device, and start a stream. Open as many tabs as you want: several devices
at once, or the same device with different filters side by side. Built with
SwiftUI and the [Lemonade design system](../lemonade-design-system).

> Status: working tool, actively built. Android logging and network capture are
> solid; iOS logging works; a couple of pieces (gRPC capture, device-ABI agent
> auto-select) are still being rounded out. See [Limitations](#limitations).

---

## What it does

**Device logs**
- Auto-discovers Android devices/emulators (`adb`), iOS simulators (`simctl`),
  and physical iOS devices (`devicectl`), live in the sidebar.
- Streams logcat (`adb logcat -v threadtime`) and iOS unified logs
  (`simctl spawn … log stream`), parsed into a structured, colour-coded list.
- Each tab is an independent session with an editable name. Filter by level,
  free text or regex, and by app — there's a searchable **app/package dropdown**
  populated from the device (`pm list packages` / `simctl listapps`).
- History of every session is saved to SQLite (with full-text search) and
  browsable per device + app, across runs.
- **App-crash detector** — counts real crashes (`FATAL EXCEPTION` / native fatal
  signal) in the stream, drops a red marker inline at each one, and a toolbar
  badge jumps you to the most recent.
- Follow-tail that **freezes the scrollback while you read** (incoming logs never
  jump your position), a Liquid-Glass "jump to latest" button, and a never-clear
  reconnect loop that survives app restarts/reinstalls (death/restart markers
  injected inline).
- Multi-line **copy** (message text only, no timestamps/tags), draggable tabs,
  `Shift`+`Tab` to cycle tabs, per-session **clear** and **export**.

**Network inspection** — three ways to capture:
1. **In-process agent** (debuggable Android apps): injects into the app process
   and reads requests/responses *before* TLS — no proxy, no CA, immune to cert
   pinning, and it even captures the **call stack** that made each request. Hooks
   `HttpURLConnection`/`HttpsURLConnection` (http and https) and both **OkHttp3
   and OkHttp2**, including request bodies. This is how Android Studio's Network
   Inspector works; Jaca reimplements it.
2. **MITM proxy** (everything else): a local HTTPS-intercepting proxy. Works for
   any app that trusts the proxy's CA; blocked by pinning. Captures full
   request/response, headers, bodies, and timing.
3. **On-device companion app** (Android, no cable): a Compose Multiplatform app you
   install on the phone captures *all* its traffic with a `VpnService` + a userspace
   TCP/IP stack, attributes each flow to the owning app, and streams it to Jaca
   desktop over gRPC/TLS on the LAN. TLS is decrypted on the **desktop** — the CA
   private key never leaves the Mac; the phone tunnels intercepted TLS to the
   desktop's proxy. Works over Wi-Fi without ADB, even on emulators, and the app
   guides you through installing the CA (no manual download).

All modes share a detail view: method/URL/status/timing, request & response
**headers with one-click copy**, bodies with a **JSON tree ⇄ raw** toggle, a
drag-to-select request **timeline**, and HAR export (proxy).

---

## How it works

### The app

A single non-sandboxed SwiftUI app (so it can shell out to `adb`/`xcrun`). The
code splits cleanly:

- `Sources/Core/` — no SwiftUI. Device discovery, log sources, the SQLite store,
  the proxy and the agent controller. Everything sits behind small protocols
  (`DeviceProvider`, `LogSource`) so a new platform is just another implementation.
- `Sources/Model/` — `AppModel` (devices + open tabs) and the `@Observable`
  session types (`LogSession`, `NetworkSession`) that back the UI.
- `Sources/Features/` — the SwiftUI views (sidebar, tab strip, log list, network
  list/detail/timeline, history, settings).

Log lines are accumulated off the main thread and flushed into the observed view
on a ~30 ms timer, so a chatty device doesn't stutter the UI.

### Network capture: the in-process agent

This is the interesting part. For a **debuggable** Android app we don't proxy at
all — we run code inside the app and instrument its HTTP stack. The mechanism
mirrors AOSP's App Inspection and is built from open-source pieces:

1. A small **native JVMTI agent** (`agent/native`, built with the NDK) is attached
   to the running app over adb with `cmd activity attach-agent` — which works on
   debuggable apps **without root**.
2. It uses AOSP's [**slicer**](https://android.googlesource.com/platform/tools/dexter)
   (vendored) to rewrite `java.net.URL.openConnection()` at load time so the method
   calls our hook on return (a JVMTI `ClassFileLoadHook` + `RetransformClasses`).
3. The hook returns a transparent **wrapper** around the returned connection —
   `HttpsURLConnection` *and* plain (cleartext) `HttpURLConnection` — that tees the
   request/response streams and records method, URL, headers, bodies, timing, and
   the initiating call stack.
4. For OkHttp it also hooks `OkHttpClient.networkInterceptors()` (an app class,
   found via `GetLoadedClasses`/`RetransformClasses`) and **injects a capture
   interceptor** — built as a reflective `java.lang.reflect.Proxy` of the
   `Interceptor` interface so the agent needn't compile against the app's OkHttp.
   Both **okhttp3** and **okhttp2** (`com.squareup.okhttp`) are hooked (routed by
   the declaring class in the exit-hook signature); request bodies are captured by
   writing the `RequestBody` into a fresh okio `Buffer`.
5. Each transaction is streamed as one JSON line over an adb-forwarded
   `localabstract` socket back to Jaca.

The interceptor is written to be **transparent to the app** — it mirrors AOSP's
`OkHttp3Interceptor`: it never consumes a one-shot/duplex request body, it rethrows
the *real* exception on a cancelled/failed call (so a `StreamResetException` can't
crash the app), and it skips the eager body peek on streaming responses
(`text/event-stream`, gRPC, long-poll) so it can't stall the app's own read.

There's a classloader subtlety that drove the design. The hook trampoline has to
live on the **bootstrap** classloader (so an instrumented boot class like `URL`
can resolve it) — but you can't put Kotlin's stdlib there without shadowing the
host app's. So the layer is split exactly like AOSP does it:

- `agent/java` — a tiny **Java** trampoline + bridge interface on the bootstrap
  loader. No Kotlin, nothing to shadow.
- `agent/kotlin` — the actual capture logic in **Kotlin**, loaded on a separate
  `DexClassLoader` (with its own bundled stdlib, isolated from the app's).

### Network capture: the proxy

For any other app, `Sources/Core/Network/ProxyServer.swift` is a swift-nio MITM
proxy. It generates a root CA and per-host leaf certs on the fly (swift-certificates),
terminates the client's TLS, and forwards upstream via `URLSession`. `NetworkSession`
auto-configures the Android device proxy (`10.0.2.2` for emulators, the Mac's LAN
IP for hardware) and the Setup sheet walks you through installing the CA.

`NetworkSession` decides per tab: debuggable target app → agent; otherwise → proxy.

---

## Build & install from source

### Prerequisites

| For | You need |
|-----|----------|
| Building the macOS app | A full **Xcode** (not just Command Line Tools) — macOS 14+ deployment target — and **XcodeGen** (`brew install xcodegen`). |
| The project's Swift packages | Fetched automatically by Xcode on first build (Lemonade is a local package at `../lemonade-design-system`, so keep it checked out next to this repo). |
| Android devices/logs/proxy | **Android SDK platform-tools** (`adb`) on your `PATH`, or set its path in Jaca's Settings. |
| iOS simulators/devices | Xcode's `simctl`; for **physical iOS logs**, `idevicesyslog` (`brew install libimobiledevice`). |
| Rebuilding the in-process agent | Android **NDK 27.2.12479018** + **CMake 3.22.1** (`sdkmanager "ndk;27.2.12479018" "cmake;3.22.1"`), **Kotlin** (`brew install kotlin`), an installed **platform** (`android-36`) and **build-tools** (for `d8`). |
| Building the companion mobile app | Android **NDK 27.2.12479018** + **CMake 3.22.1** (the on-device capture is a zdtun JNI library) and a **JDK 17+**; built with Gradle via `./scripts/build-mobile.sh`. Plus a device/emulator to install it on. |

### Quick start — one script for everything

```bash
git clone <repo-url> jaca && cd jaca
./scripts/all.sh                  # build the agent + the app, then launch
```

`scripts/all.sh` is the whole workflow in one command: it builds the **Android
in-process agent** (`.so` + dexes), generates the Xcode project, builds the macOS
app, and launches it. The agent step is **best-effort** — if its NDK/Kotlin
toolchain isn't installed it's skipped with a hint, and the app still builds (proxy
capture works without the agent). Useful flags:

```bash
./scripts/all.sh --release        # optimized build
./scripts/all.sh --install        # build Release + copy into /Applications + launch
./scripts/all.sh --no-agent       # skip the agent build
./scripts/all.sh --no-run         # build only, don't launch
```

### Individual steps

The repo has no committed Xcode project — it's generated from `project.yml` by
XcodeGen. The `scripts/` set `DEVELOPER_DIR` to Xcode automatically (handy when
`xcode-select` points at the CLT).

```bash
./scripts/run.sh           # generate the project, build (Debug), and launch
./scripts/gen.sh           # regenerate Jaca.xcodeproj from project.yml (XcodeGen)
./scripts/build.sh         # build only (Debug)
./scripts/build.sh Release # build optimized
./scripts/uitest.sh        # run the XCUITest UI suite (clears stray instances first)
```

To **install** the built app, copy the `.app` into `/Applications`:

```bash
./scripts/build.sh Release
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/Jaca-*/Build/Products/Release/Jaca.app | head -1)
cp -R "$APP" /Applications/
open /Applications/Jaca.app
```

> The app is intentionally **non-sandboxed** so it can shell out to `adb`/`xcrun`.
> It's signed for local development; macOS Gatekeeper may ask you to allow it the
> first time (right-click → Open, or System Settings → Privacy & Security).

### One-time: stop the Keychain prompt (recommended)

The MITM CA's private key lives in your macOS Keychain. Because ad-hoc debug builds get
a new code signature on each rebuild, macOS re-asks *"Jaca wants to use … in your
keychain"* on every launch. Fix it once:

```bash
./scripts/dev-signing.sh    # creates a stable "Jaca Dev" identity — authorize the one trust prompt
```

After that, `build.sh` re-signs the app with that stable identity, so the first **Always
Allow** you click on the CA-key prompt sticks across rebuilds. It's optional — skip it and
builds stay ad-hoc (you'll just keep getting the prompt).

### Building the companion mobile app

The on-device companion (Android) lives under `mobile/` (Compose Multiplatform). Build and
bundle its APK into the desktop app — which serves it for QR onboarding — with:

```bash
./scripts/build-mobile.sh        # assembles the APK + copies it into Resources/
./scripts/proto-gen.sh           # regenerate gRPC stubs after editing proto/companion.proto
```

Needs the Android **NDK 27.2.12479018** + **CMake 3.22.1** (the capture path is a zdtun JNI
library) and a **JDK 17+**. Install it by scanning the QR in Jaca's **Connect a device**
sheet, or `adb install Resources/jaca-mobile.apk`. Open the app, start capture, and it shows
up in Jaca's device list automatically; the desktop pushes its CA over the link and the app
walks you through trusting it — no manual download.

### Building the Android agent (optional — only for the in-process capture mode)

The proxy capture mode needs nothing extra. The **in-process agent** needs its
native `.so` + two dexes built once; the app loads them from `agent/out/` (or, if
present, its own bundle). These artifacts are **not checked in** — build them with:

```bash
cd agent
./build.sh         # native JVMTI .so per ABI (arm64-v8a, x86_64), via NDK + vendored slicer
./build-dex.sh     # boot dex (javac) + capture dex (kotlinc + d8)
./deploy.sh [pkg] [serial]   # build + attach to a debuggable app + tail — for iteration
```

`build.sh` honours `ABIS="arm64-v8a x86_64"` and `API=28`; `deploy.sh` defaults to
`com.teya.ac.dev` on `emulator-5554` (override with the two args, or `ANDROID_SERIAL`).

---

## Repository layout

```
jaca/
  project.yml              XcodeGen spec (Lemonade + swift-nio/certificates deps)
  scripts/                 gen / build / run / uitest
  Sources/
    App/                   SwiftUI entry, root shell, app icon
    Core/Devices/          DeviceProvider + Android/iOS backends, installed-apps
    Core/Logs/             LogSource, logcat/ndjson/syslog parsers, LogFilter, CrashDetector
    Core/Persistence/      HistoryStore (libsqlite3 + FTS5)
    Core/Process/          ProcessRunner (Process -> AsyncStream)
    Core/Network/          ProxyServer, CertificateAuthority, AgentController, AgentArtifacts, …
    Features/              SwiftUI views (sidebar, tabs, log list, network detail, …)
    Model/                 AppModel, LogSession, NetworkSession
  Tests/                   unit + live integration (XCTest)
  UITests/                 XCUITest
  agent/
    native/                JVMTI agent (C++) + vendored AOSP slicer (third_party/)
    java/                  bootstrap trampoline + bridge interface (Java)
    kotlin/                capture logic (Kotlin): OkHttpHook, Tracked*URLConnection, SqueezeTracker, …
    out/                   built artifacts (.so + dexes) — generated, not committed
```

### Notable dependencies

- **Lemonade** — the design system (local SwiftUI package).
- **swift-nio / swift-nio-ssl / swift-certificates / swift-crypto** — the MITM proxy.
- **libsqlite3** — history store (system library, no wrapper).
- **AOSP slicer** — vendored dex rewriter for the agent (`agent/native/third_party`).

---

## Limitations

Honest about what each capture mode can and can't do:

- **Agent (in-process):** debuggable apps only (a debug build — re-signing a
  release build to attach trips signature/attestation checks, so it's out of
  scope). Hooks `HttpURLConnection`/`HttpsURLConnection` and **OkHttp3 + OkHttp2**
  (incl. ktor-over-OkHttp), which covers the bulk of modern apps; **gRPC** is still
  on the list. Captured bodies are capped at ~1 MB each. Currently pushes the
  `arm64-v8a` build (device-ABI auto-select is pending). It's the only mode that
  gives you the request call stack.
- **Proxy:** works for any app, but the app must trust the installed CA — release
  builds that pin certificates or don't trust user CAs can't be decrypted. No call
  stack (impossible from outside the process).
- **iOS network:** there is no system-level inspector like Android's, so iOS is
  proxy-only with the same CA/pinning caveats.
- **Physical iOS logs:** need `idevicesyslog` (`brew install libimobiledevice`);
  you get the device syslog, not a clean per-app stream like Android.

---

## Tests

```bash
xcodebuild -scheme Jaca -only-testing:JacaTests test   # logic + live integration
./scripts/uitest.sh                                          # UI flows
```

The suite includes live tests that exercise real devices when present (Android
emulator, iOS simulator, the MITM proxy via curl, and the in-process agent against
a debuggable app), and skip cleanly when they aren't.
