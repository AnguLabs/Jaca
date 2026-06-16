---
name: investigate-loggingsupport
description: >-
  Re-investigate, validate, and repair Jaca's physical-device structured log streaming when a new
  macOS/Xcode version breaks it. Jaca streams Xcode/Console-grade device logs (level + subsystem +
  category + message) by dlopen'ing Apple's PRIVATE LoggingSupport.framework (OSActivityStream) +
  MobileDevice.framework — undocumented APIs that shift between OS/Xcode releases. Use this when the
  iOS physical-device log stream stops/empties/crashes, dlopen fails, there's an "unrecognized
  selector" on OSActivityStream/OSLogDevice, levels or fields come out wrong, or right after a macOS
  or Xcode upgrade. It walks the exact extract → probe → dump → prototype → validate methodology that
  derived the working integration, with copy-paste commands and a known-good reference prototype.
---

# Repairing Jaca's LoggingSupport device-log integration

## What this is

Jaca shows **full structured logs from a physical iPhone** — level (Debug/Info/Default/Error/Fault),
subsystem, category, process, composed message — exactly like Xcode's console and the iOS Simulator.

It does **not** get this from `devicectl` or `idevicesyslog`:
- `devicectl device process launch --console` → flat stderr mirror, **0 level tokens**, must launch the app, needs the device unlocked.
- `idevicesyslog` → has levels but flat (sender image, not category), `<private>`-redacted, no `print()`.

Instead Jaca `dlopen`s **two private Apple frameworks** and drives Apple's own log engine — the same
one Console.app uses:

| Framework | Path | Role |
|---|---|---|
| `MobileDevice.framework` | `/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice` | `AMDeviceRef` for a UDID (the device handle) |
| `LoggingSupport.framework` | `/System/Library/PrivateFrameworks/LoggingSupport.framework/LoggingSupport` | `OSActivityStream` → structured events from the device's `com.apple.os_trace_relay` service |

The stream is **passive**: no app launch, no device-unlock, no relaunch. It's whole-device; filter by
`subsystem`/`process` for one app.

**Why this skill exists:** these frameworks are private and undocumented. A macOS/Xcode upgrade can
rename classes or selectors, change the option/level bit values, or relocate the framework — which
breaks the integration with a crash or an empty stream. This runbook re-derives everything from
scratch and tells you how to fold the findings back into Jaca.

## The proven working recipe (baseline: macOS 26 / Xcode `devicectl` 518.31 / iOS 26.5, 2026-06)

```
1. MobileDevice:  AMDCreateDeviceList() → find the entry whose AMDeviceCopyDeviceIdentifier == UDID;
                  AMDeviceConnect(dev).   (AMDeviceIsPaired may return 0 even when paired — do NOT gate on it.)
2. id dev    = [[OSLogDevice alloc] initWithMobileDevice:amDeviceRef andUDID:@"<UDID>"];
3. id stream = [[OSActivityStream alloc] init];     // NOT initWithDevice: — that overload takes void* and silently drops it
   [stream setDevice:dev];                          // setDevice:(id) stores the OSLogDevice (scopes the stream to it)
   [stream setDelegate:delegate];                   // and setDeviceDelegate:
   [stream setOptions:(INFO|DEBUG|PAYLOAD)];        // 0x100 | 0x20 | 0x04 = 0x124
   [stream setEventFilter:0xFFFFFFFF];              // all activity-stream event types
   [stream startRemote];                            // do NOT call establishTrust: — internal; startRemote does trust
4. Events arrive on the delegate -activityStream:results: as an NSArray of
   OSActivityLogMessageEvent (subclass of OSActivityEventMessage : OSActivityEvent).
   Run [[NSRunLoop currentRunLoop] run] so the dispatch callbacks deliver.
```

**Event fields** (`OSActivityLogMessageEvent`): `messageType` (unsigned char = level), `subsystem`,
`category`, `process`, `processID`, `sender`, `eventMessage` (fully decoded message — `format` is nil
once PAYLOAD-decoded), `timestamp`, `machTimestamp`, `threadID`, `processImagePath`, `senderImagePath`.

**Level map** (`messageType`): `0x00 Default · 0x01 Info · 0x02 Debug · 0x10 Error · 0x11 Fault`.

**Private data:** ~75% of fields stream unredacted; ~25% show `<private>` where the call site marked a
field private. To unredact those, install the **Enable-Private-Data** configuration profile on the
device (orthogonal to this integration). Xcode only avoids redaction because it *debugs* the process;
passive streaming (this path, Console.app, `log stream`) redacts without the profile.

A complete, compile-and-run reference implementation is at **`reference/oslogstream.m`**.

## Symptom → likely cause

| Symptom | Likely cause | Go to |
|---|---|---|
| `dlopen` returns NULL | framework moved/renamed | Step 1 |
| Classes missing (`objc_getClass` nil) | class renamed | Step 2, 3 |
| `unrecognized selector` at runtime | selector renamed/signature changed | Step 2 |
| Stream starts but 0 events | option/filter bits changed, or wrong start method | Step 2 (flags), Step 4 |
| Events arrive but level/subsystem/message empty | field selectors or `messageType` enum changed | Step 2 (fields), Step 3 |
| Crash in `objc_retain`/`establishTrust:` | calling an internal method, or wrong arg type | "Known pitfalls" |

## Investigation methodology — re-run ALL of this when it breaks

### Step 0 — Free the device, confirm it's reachable
```bash
pkill -x Jaca; pkill -9 -f idevicesyslog        # avoid os_trace_relay contention
UDID=$(xcrun devicectl list devices --json-output /tmp/d.json >/dev/null 2>&1; \
       python3 -c "import json;print(json.load(open('/tmp/d.json'))['result']['devices'][0]['hardwareProperties']['udid'])")
echo "UDID=$UDID"
xcrun devicectl device info lockState --device "$UDID"   # passcodeRequired:true == locked (this path doesn't need unlock, but good to know)
```

### Step 1 — Does the framework still load? (dlopen probe)
See `reference/probes.md` § "dlopen probe". Confirms the two frameworks load and the key classes exist
(`OSActivityStream`, `OSLogDevice`, `OSActivityLogMessageEvent`, `OSLogEventProxy`). If a class is
missing, its name changed → Step 3 to find the new name.

### Step 2 — Are the selectors still there? (runtime method dump)
See `reference/probes.md` § "method dump". `dlopen` + `class_copyMethodList` on `OSActivityStream`,
`OSLogDevice`, and the event class. Confirm these selectors still exist (rename in code if not):
`initWithMobileDevice:andUDID:`, `setDevice:`, `setDelegate:`, `setDeviceDelegate:`, `setOptions:`,
`setEventFilter:`, `startRemote`, `stopRemote`; delegate `activityStream:results:` /
`activityStream:deviceUDID:deviceID:status:error:`; event fields `messageType`, `subsystem`,
`category`, `process`, `processID`, `eventMessage`, `timestamp`.

### Step 3 — If symbols changed: extract the dyld cache + mine
`LoggingSupport` is **shared-cache-only** (no standalone binary). Extract it, then mine with the
already-present tools — see `reference/probes.md` § "extract + mine":
- `/usr/lib/dsc_extractor.bundle` is on disk → a ~30-line C tool calls
  `dyld_shared_cache_extract_dylibs_progress()` to extract dylibs to a dir.
- Then `otool -v -s __TEXT __objc_classname/__objc_methname`, `nm -arch arm64e | xcrun swift-demangle`,
  `otool -ov` on the extracted `LoggingSupport`.
- Grep selectors for `log|oslog|console|stream|device|udid|subsystem|category|messageType|activate|start`.
- Re-discover flag/enum values from `strings`/disassembly if `setOptions:`/`messageType` mappings stopped working.
- Standalone frameworks (`CoreDevice`, `MobileDevice`, `RemotePairing` under `/Library/...`) need no extraction.

### Step 4 — Rebuild & validate the prototype against the real device
```bash
clang -fobjc-arc -framework Foundation -framework CoreFoundation \
  -Wno-objc-method-access -o /tmp/oslogstream <skill>/reference/oslogstream.m   # patch any renamed selectors first
/tmp/oslogstream "$UDID" 10 > /tmp/proto.txt 2>&1
grep -cE '^[0-9]{4}-' /tmp/proto.txt                                   # expect thousands
grep -oE ' (Default|Info|Debug|Error|Fault) ' /tmp/proto.txt | sort | uniq -c   # MUST show multiple levels incl. Debug
```
Success = thousands of lines with a real **level distribution** (Debug/Info/Default/Error present) and
populated subsystem/category/message. (A flat or single-level result means a field/flag regressed.)

### Step 5 — Fold findings back into Jaca
The Swift integration lives in the iOS-device log source (a `LogSource` that dlopens these frameworks
via a thin ObjC/ObjC++ bridge — Swift can't call private classes directly). Update the bridge's
selector strings / flag constants / level map to match what Steps 2–4 found. Keep the **defensive
fallback**: if `dlopen` or `objc_getClass` fails, log a clear user-visible message ("Apple LoggingSupport
private API unavailable on this macOS/Xcode build — falling back") and fall back to `idevicesyslog`
(levels, flat) or `devicectl --console` (print, no levels). Never hard-crash on a private-API miss.

## Known pitfalls (each cost an iteration — do not repeat)
- `OSLogEventLiveStream`/`OSLogEventLiveSource` are the **local-Mac** path; `OSLogEventLiveSource` is an
  empty stub for remote devices. The **remote-device** engine is **`OSActivityStream`**.
- `OSActivityStream -initWithDevice:` is encoded `(^v)` (void*) and **silently does not store** the
  device. Use `init` then `setDevice:(id)`.
- Do **not** call `establishTrust:` — it's internal; passing an `NSError**` or the device crashes in
  `objc_retain`. `startRemote` performs the trust handshake itself.
- Live events are **`OSActivityLogMessageEvent`**, NOT `OSLogEventProxy` (the latter is the
  persisted-store model with `logType`/`composedMessage`). Use `messageType`/`eventMessage`.
- `AMDeviceIsPaired` returned `0` even though streaming worked — don't gate on it.
- The stream is a **firehose** (~1,400 events/sec whole-device) — buffer off-main and flush on a timer
  (Jaca's existing logcat/proxy pattern), and filter by subsystem/process.

## Reference constants
- os_activity_stream options: `PROCESS_ONLY=0x1, SKIP_DECODE=0x2, PAYLOAD=0x4, HISTORICAL=0x8,`
  `CALLSTACK=0x10, DEBUG=0x20, BUFFERED=0x40, NO_SENSITIVE=0x80, INFO=0x100, PROMISCUOUS=0x200,`
  `PRECISE_TIMESTAMPS=0x400`. (Jaca uses `INFO|DEBUG|PAYLOAD = 0x124`; leave `NO_SENSITIVE` OFF.)
- Device service: `com.apple.os_trace_relay` (structured tracev3) vs `com.apple.syslog_relay` (flat).
- Transport (iOS 17+): RemoteServiceDiscovery (`remoted`/`remotectl`) + `remotepairingd` tunnel
  (`utun`, IPv6 `fd2e:…::1`) + RemoteXPC — all handled inside `LoggingSupport`/`MobileDevice`.

## Reference files
- `reference/oslogstream.m` — the proven, compile-and-run prototype (whole-device structured stream).
- `reference/probes.md` — the dlopen / method-dump / class-finder / dyld-extract probes used to derive it.
