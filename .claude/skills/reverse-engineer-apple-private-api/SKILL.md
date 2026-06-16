---
name: reverse-engineer-apple-private-api
description: >-
  Methodology to locate, decompile, read, and call ANY Apple private framework / SPI from Jaca (a
  non-sandboxed macOS developer tool). Use when you need a capability Apple ships in a tool (Xcode,
  Console.app, Instruments, simctl, devicectl) but exposes no public API for — e.g. structured device
  logs, network/diagnostic relays, device pairing, code injection — and need to find which framework
  owns it, dump its classes/selectors/constants, prototype a call, and wire it into Jaca with a
  fail-soft bridge. Also use to repair such an integration after a macOS/Xcode upgrade shifts symbols.
  Worked example: the `investigate-loggingsupport` skill (physical-device structured logs).
---

# Reverse-engineering Apple private frameworks for Jaca

Jaca is a non-sandboxed developer tool, so it may `dlopen` private frameworks and call SPI that
App-Store apps can't. The trade-off: these APIs are undocumented and can change between OS/Xcode
releases. This is the repeatable methodology to (a) discover the right framework + API, (b) prove a
call works, and (c) integrate it defensively. Treat every private-API integration as "verify, then
fail soft."

**Golden rule:** before reaching for private API, check for a public one (a CLI like `devicectl`/
`simctl`, a public framework class, or an env var/diagnostic mode). Private API is the last resort,
and even then prefer the *highest-level* private class (Apple's own engine) over re-implementing a
wire protocol.

## Phase 1 — Find which framework owns the capability

You usually know the *behavior* (Xcode shows X), not the framework. Triangulate:

```bash
# a) What does the tool that already does it link against?
TOOL=$(xcrun -f devicectl)           # or simctl, instruments, etc. (note: may be a shim → find the real Mach-O)
otool -L "$TOOL" | grep -iE "private|framework"
# b) Which daemon mediates it? Watch the system log while triggering the behavior:
sudo log stream --predicate 'process == "<daemon>"'    # e.g. remotepairingd, remoted
# c) Search frameworks by capability keyword:
mdfind -name .framework | grep -iE "logging|remote|coredevice|instruments"
ls /System/Library/PrivateFrameworks /Library/Apple/System/Library/PrivateFrameworks \
   /Applications/Xcode.app/Contents/SharedFrameworks /Library/Developer/PrivateFrameworks
# d) Xcode-side glue often lives in SharedFrameworks (DVT*, IDE*, *Host) and consumes the device framework.
```
Service identifiers (`com.apple.*`) are a strong signal — grep candidate binaries' `strings` for them.

## Phase 2 — Locate the binary (standalone vs shared cache)

```bash
F=/System/Library/PrivateFrameworks/Foo.framework/Foo
file "$F" 2>/dev/null && otool -L "$F"      # standalone? then no extraction needed
```
Most `/System/...` frameworks are **dyld-shared-cache-only** (the dir has only `Resources/`, no Mach-O).
Extract with the on-box `dsc_extractor.bundle` (always present):
```bash
cat > /tmp/dscx.c <<'EOF'
#include <dlfcn.h>
typedef int(*fn)(const char*,const char*,void(^)(unsigned,unsigned));
int main(int c,char**v){void*h=dlopen("/usr/lib/dsc_extractor.bundle",RTLD_NOW);
fn f=(fn)dlsym(h,"dyld_shared_cache_extract_dylibs_progress");return f(v[1],v[2],^(unsigned a,unsigned b){});}
EOF
clang -o /tmp/dscx /tmp/dscx.c
CACHE=$(ls /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e 2>/dev/null || ls /System/Library/dyld/dyld_shared_cache_arm64e)
/tmp/dscx "$CACHE" /tmp/dsc_out      # ~1 min; extracts all dylibs
```
`/Library/...` and Xcode `SharedFrameworks` binaries are usually standalone — inspect directly.

## Phase 3 — Mine the API surface (static)

```bash
F=/tmp/dsc_out/System/Library/PrivateFrameworks/Foo.framework/Versions/A/Foo   # or the standalone path
otool -v -s __TEXT __objc_classname "$F" | grep -iE "<keyword>"     # class names
otool -v -s __TEXT __objc_methname  "$F" | grep -iE "<keyword>"     # selectors
nm -arch arm64e "$F" | xcrun swift-demangle | grep -iE "<keyword>"  # Swift symbols
strings -a "$F" | grep -iE "com\.apple\.|<service-id>|<constant>"   # service ids / enum hints
```
`class-dump` (if installed: `brew install class-dump`) gives full ObjC interfaces; otherwise the
runtime dump (Phase 4) is more reliable on modern ObjC.

## Phase 4 — Runtime introspection (the source of truth)

`dlopen` + the ObjC runtime beats static parsing for current selectors/availability. Three probes:

```objc
// (1) load probe — does it load + are the classes present?
void *h = dlopen("/System/Library/PrivateFrameworks/Foo.framework/Foo", RTLD_NOW);
printf("%s\n", h ? "OK" : dlerror());
printf("%s\n", objc_getClass("FooStream") ? "FOUND" : "missing");

// (2) method dump — exact selectors (class + instance):
Class c = objc_getClass("FooStream"); unsigned n;
Method *m = class_copyMethodList(object_getClass(c), &n);   // class methods (+)
m = class_copyMethodList(c, &n);                            // instance methods (-)
for (unsigned i=0;i<n;i++) puts(sel_getName(method_getName(m[i])));

// (3) class finder — locate a renamed class/selector across ALL loaded classes:
unsigned k; Class *all = objc_copyClassList(&k);
for (unsigned i=0;i<k;i++) if (strcasestr(class_getName(all[i]), "<keyword>")) puts(class_getName(all[i]));
```
Compile: `clang -framework Foundation -o /tmp/probe /tmp/probe.m && /tmp/probe`.
(See the `investigate-loggingsupport` skill's `reference/probes.md` for fuller copy-paste versions.)

## Phase 5 — Prototype the call (iterate against the real target)

Write a tiny ObjC CLI that `dlopen`s the framework and drives the API via `objc_msgSend` casts (no
headers needed) or `extern`-declared + `dlsym`'d C functions. Iterate compile → run → fix until it
produces real output. Keep the prototype — it becomes the skill's reference + the integration spec.

```bash
clang -fobjc-arc -framework Foundation -Wno-objc-method-access -o /tmp/proto /tmp/proto.m && /tmp/proto
```
Validate against ground truth (e.g. compare to what Xcode/Console shows), not just "no crash."

## Phase 6 — Integrate into Jaca, fail-soft

Swift can't call private classes directly → put all private-API access in a thin **Objective-C bridge**
(`.h`/`.m`) exposed via the bridging header (`SWIFT_OBJC_BRIDGING_HEADER`, `CLANG_ENABLE_OBJC_ARC` in
`project.yml`; see `Sources/Core/Logs/JacaOSLog.{h,m}` for the reference pattern). The bridge must:
- `dlopen` lazily and **return nil/NO** if the framework or any class/selector is missing.
- never hard-crash on a private-API miss — Swift catches the nil and **falls back** to a supported path,
  surfacing a clear user-visible message ("Apple <Foo> private API unavailable on this build — falling back").
- isolate every `objc_msgSend`/`dlsym` so a signature change is contained to one file.

## Known pitfalls (cost real iterations)
- **ARC + `objc_msgSend`:** cast to the exact function-pointer signature per call; follow selector naming
  for ownership (`alloc`/`new`/`copy`/`init` → +1). `-fobjc-arc` works with these casts (it's what we use).
- **`void*` vs `id` init overloads:** some classes have an `initWith…:` encoded `(^v)` that silently
  drops its argument. Verify the object actually retained your input (check an ivar); prefer `init` +
  a setter when an overload misbehaves.
- **Empty stub classes:** a class can exist but have no usable methods (it's the *local* variant, or a
  facade). Find the real engine via the class finder (Phase 4) — e.g. the remote-device log engine is
  `OSActivityStream`, not the empty `OSLogEventLiveSource`.
- **Internal methods that crash:** don't call setup/`establishTrust:`-style methods that the high-level
  `start…` already performs; passing the wrong arg type crashes in `objc_retain`.
- **dyld-cache-only frameworks** need extraction (Phase 2) to read symbols, but still `dlopen` fine at
  runtime from their nominal path.
- **Sandbox/signing:** `dlopen` of `/System` & `/Library` private frameworks requires the app to be
  **non-sandboxed** (Jaca already is) and hardened-runtime off or with the right exceptions.

## When the easy path exists, take it
Not every capability needs a private framework. Public/near-public routes worth checking first:
`devicectl`/`simctl`/`remotectl` subcommands, env vars (`OS_ACTIVITY_DT_MODE`, `CFNETWORK_DIAGNOSTICS`,
`SIMCTL_CHILD_*`, `DYLD_INSERT_LIBRARIES`), public framework classes (`NSURLProtocol`, `OSLog`), and
diagnostic profiles. Document why the easy path was insufficient before going private.
