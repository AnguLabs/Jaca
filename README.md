# Squeeze

A native macOS app for watching what your connected devices are doing — their
logs and their network traffic — in a fast, multi-tab "terminal" UI.

Point it at an Android emulator, a physical Android phone, or an iOS simulator,
pick a device, and start a stream. Open as many tabs as you want: several devices
at once, or the same device with different filters side by side. Built with
SwiftUI and the [Lemonade design system](../lemonade-design-system).

> Status: working tool, actively built. Android logging and network capture are
> solid; iOS logging works; some pieces (multi-arch agent, gRPC) are still being
> rounded out. See [Limitations](#limitations).

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
- Follow-tail with auto-pause when you scroll up, clear, export.

**Network inspection** — two ways to capture, picked automatically:
1. **In-process agent** (debuggable Android apps): injects into the app process
   and reads requests/responses *before* TLS — no proxy, no CA, immune to cert
   pinning, and it even captures the **call stack** that made each request. This
   is how Android Studio's Network Inspector works; Squeeze reimplements it.
2. **MITM proxy** (everything else): a local HTTPS-intercepting proxy. Works for
   any app that trusts the proxy's CA; blocked by pinning. Captures full
   request/response, headers, bodies, and timing, with a drag-to-select timeline
   and HAR export.

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
3. The hook returns a transparent **wrapper** around the `HttpsURLConnection` that
   tees the request/response streams and records method, URL, headers, bodies,
   timing, and the initiating call stack.
4. For OkHttp it also hooks `okhttp3.OkHttpClient.networkInterceptors()` (an app
   class, found via `GetLoadedClasses`/`RetransformClasses`) and **injects a capture
   interceptor** — built as a reflective `java.lang.reflect.Proxy` of
   `okhttp3.Interceptor` so the agent needn't compile against the app's OkHttp.
5. Each transaction is streamed as one JSON line over an adb-forwarded
   `localabstract` socket back to Squeeze.

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

## Build & run

Requires a full **Xcode** (not just Command Line Tools) and the Android SDK.

```bash
cd squeeze
./scripts/run.sh          # generate the project, build, and launch
```

The scripts set `DEVELOPER_DIR` to Xcode automatically (handy when `xcode-select`
points at the CLT). Other entry points:

```bash
./scripts/gen.sh          # regenerate Squeeze.xcodeproj from project.yml (XcodeGen)
./scripts/build.sh        # build only
./scripts/uitest.sh       # run the XCUITest UI suite (clears stray instances first)
```

### Building the Android agent

The agent ships as prebuilt artifacts the app pushes to the device. To rebuild
them you need the NDK + CMake (`sdkmanager "ndk;27.2.12479018" "cmake;3.22.1"`)
and Kotlin (`brew install kotlin`):

```bash
cd agent
./build.sh        # native JVMTI .so (per ABI), via NDK + vendored slicer
./build-dex.sh    # boot dex (javac) + capture dex (kotlinc + d8)
./deploy.sh [pkg] # build, attach to a debuggable app, tail the agent — for iteration
```

---

## Repository layout

```
squeeze/
  project.yml              XcodeGen spec (Lemonade + swift-nio/certificates deps)
  scripts/                 gen / build / run / uitest
  Sources/
    App/                   SwiftUI entry, root shell, app icon
    Core/Devices/          DeviceProvider + Android/iOS backends, installed-apps
    Core/Logs/             LogSource, logcat/ndjson/syslog parsers, LogFilter
    Core/Persistence/      HistoryStore (libsqlite3 + FTS5)
    Core/Process/          ProcessRunner (Process -> AsyncStream)
    Core/Network/          ProxyServer, CertificateAuthority, AgentController, …
    Features/              SwiftUI views
    Model/                 AppModel, LogSession, NetworkSession
  Tests/                   unit + live integration (XCTest)
  UITests/                 XCUITest
  agent/
    native/                JVMTI agent (C++) + vendored AOSP slicer
    java/                  bootstrap trampoline (Java)
    kotlin/                capture logic (Kotlin)
```

Roughly 5.9k lines of Swift and 3.2k of agent code (excluding vendored slicer).

### Notable dependencies

- **Lemonade** — the design system (local SwiftUI package).
- **swift-nio / swift-nio-ssl / swift-certificates / swift-crypto** — the MITM proxy.
- **libsqlite3** — history store (system library, no wrapper).
- **AOSP slicer** — vendored dex rewriter for the agent (`agent/native/third_party`).

---

## Limitations

Honest about what each capture mode can and can't do:

- **Agent (in-process):** debuggable apps only; hooks `HttpURLConnection`/
  `HttpsURLConnection` **and `okhttp3`** (including ktor-over-OkHttp), which covers
  the bulk of modern apps. OkHttp2 and gRPC are still on the list. It's the only
  mode that gives you the request call stack.
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
xcodebuild -scheme Squeeze -only-testing:SqueezeTests test   # logic + live integration
./scripts/uitest.sh                                          # UI flows
```

The suite includes live tests that exercise real devices when present (Android
emulator, iOS simulator, the MITM proxy via curl, and the in-process agent against
a debuggable app), and skip cleanly when they aren't.
