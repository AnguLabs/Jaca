# Probes — re-deriving the LoggingSupport API surface

Copy-paste probes used to discover and validate the private-framework integration. Run them in order
when `../SKILL.md` Step 1–3 sends you here. All are read-only.

Paths (baseline macOS 26):
- LoggingSupport: `/System/Library/PrivateFrameworks/LoggingSupport.framework/LoggingSupport` (shared-cache only)
- MobileDevice:  `/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice` (standalone)

---

## 1. dlopen probe — does the framework load and do the classes exist?

```bash
cat > /tmp/lsprobe.m <<'EOF'
#include <dlfcn.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>
int main(){
  void *h = dlopen("/System/Library/PrivateFrameworks/LoggingSupport.framework/LoggingSupport", RTLD_NOW);
  printf("dlopen LoggingSupport: %s\n", h ? "OK" : dlerror());
  const char* names[] = {"OSActivityStream","OSLogDevice","OSActivityLogMessageEvent",
                         "OSActivityEvent","OSActivityEventMessage","OSLogEventProxy",
                         "OSLogEventLiveStream","OSLogEventLiveSource",0};
  for (int i=0; names[i]; i++){ Class c = objc_getClass(names[i]); printf("  %-26s %s\n", names[i], c?"FOUND":"missing"); }
  return 0;
}
EOF
clang -framework Foundation -o /tmp/lsprobe /tmp/lsprobe.m && /tmp/lsprobe
```
Expect LoggingSupport=OK and `OSActivityStream`, `OSLogDevice`, `OSActivityLogMessageEvent` FOUND.
If a class is `missing`, it was renamed → run probe 3 to find the new name.

---

## 2. method dump — confirm the exact selectors (class + instance)

```bash
cat > /tmp/lsdump.m <<'EOF'
#include <dlfcn.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>
static void dump(const char *name){
  Class c=objc_getClass(name); if(!c){printf("[%s] MISSING\n",name);return;}
  printf("\n===== %s =====\n", name);
  unsigned n=0; Method *m=class_copyMethodList(object_getClass(c),&n);
  for(unsigned i=0;i<n;i++) printf("  +%s\n", sel_getName(method_getName(m[i]))); free(m);
  m=class_copyMethodList(c,&n);
  for(unsigned i=0;i<n;i++) printf("  -%s\n", sel_getName(method_getName(m[i]))); free(m);
}
int main(){
  dlopen("/System/Library/PrivateFrameworks/LoggingSupport.framework/LoggingSupport", RTLD_NOW);
  dump("OSActivityStream"); dump("OSLogDevice"); dump("OSActivityLogMessageEvent");
  return 0;
}
EOF
clang -framework Foundation -o /tmp/lsdump /tmp/lsdump.m && /tmp/lsdump
```
Confirm these still exist (rename in `oslogstream.m` + the Jaca bridge if any changed):
`OSActivityStream`: `-init`, `-setDevice:`, `-setDelegate:`, `-setDeviceDelegate:`, `-setOptions:`,
`-setEventFilter:`, `-startRemote`, `-stopRemote`.
`OSLogDevice`: `-initWithMobileDevice:andUDID:`, `-mobileDeviceRef`.
`OSActivityLogMessageEvent`: `-messageType`, `-subsystem`, `-category`, `-process`, `-processID`,
`-eventMessage`, `-timestamp`, `-sender`.

---

## 3. class finder — locate a renamed class/selector across all loaded classes

```bash
cat > /tmp/lsfind.m <<'EOF'
#include <dlfcn.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>
static BOOL has(Class c,const char*s){return class_getInstanceMethod(c,sel_registerName(s))||class_getClassMethod(c,sel_registerName(s));}
int main(int argc,char**argv){
  dlopen("/System/Library/PrivateFrameworks/LoggingSupport.framework/LoggingSupport", RTLD_NOW);
  unsigned n=0; Class *all=objc_copyClassList(&n);
  for(unsigned i=0;i<n;i++){
    const char*cn=class_getName(all[i]);
    // print classes whose name contains the substring argv[1] (e.g. "Activity", "OSLog")
    if(argc>1 && strcasestr(cn,argv[1])) printf("class: %s\n",cn);
    // and any class implementing the selector argv[2] (e.g. "startRemote")
    if(argc>2 && has(all[i],argv[2])) printf("  %s implements %s\n",cn,argv[2]);
  }
  free(all); return 0;
}
EOF
clang -framework Foundation -o /tmp/lsfind /tmp/lsfind.m
/tmp/lsfind Activity startRemote     # find Activity* classes + whoever implements startRemote
/tmp/lsfind OSLog setDevice
```

---

## 4. extract the dyld shared cache + mine symbols (when probes 1–3 can't find names)

`LoggingSupport` has no standalone binary — extract it from the cache (the supported on-box tool
`/usr/lib/dsc_extractor.bundle` is present), then use `otool`/`nm`/`swift-demangle`.

```bash
cat > /tmp/dscx.c <<'EOF'
#include <stdio.h>
#include <dlfcn.h>
typedef int (*extractor_t)(const char*, const char*, void(^)(unsigned,unsigned));
int main(int argc,char**argv){
  void*h=dlopen("/usr/lib/dsc_extractor.bundle",RTLD_NOW);
  extractor_t f=(extractor_t)dlsym(h,"dyld_shared_cache_extract_dylibs_progress");
  if(!f){fprintf(stderr,"no extractor\n");return 1;}
  return f(argv[1], argv[2], ^(unsigned a,unsigned b){});
}
EOF
clang -o /tmp/dscx /tmp/dscx.c
CACHE=$(ls /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e 2>/dev/null \
        || ls /System/Library/dyld/dyld_shared_cache_arm64e)
/tmp/dscx "$CACHE" /tmp/dsc_out          # extracts all dylibs (takes a minute)
LS=/tmp/dsc_out/System/Library/PrivateFrameworks/LoggingSupport.framework/Versions/A/LoggingSupport

# mine selectors / class names / strings:
otool -v -s __TEXT __objc_classname "$LS" | grep -iE "activity|oslog|device|stream"
otool -v -s __TEXT __objc_methname  "$LS" | grep -iE "device|udid|option|filter|remote|messageType|subsystem|category|eventMessage"
nm -arch arm64e "$LS" | xcrun swift-demangle | grep -iE "activity|stream|device"
strings -a "$LS" | grep -iE "os_trace_relay|os_activity_stream|com\.apple\.coredevice"
```
Standalone frameworks (`MobileDevice`, `CoreDevice`, `RemotePairing` under `/Library/...`) need no
extraction — run `otool -L`/`nm`/`otool -ov` on them directly. For ObjC class layouts, `class-dump`
is ideal but isn't installed (`brew install class-dump` or `blacktop/tap/ipsw`).

---

## 5. validate end-to-end (the real test)

```bash
clang -fobjc-arc -framework Foundation -framework CoreFoundation -Wno-objc-method-access \
  -o /tmp/oslogstream "$(dirname "$0")/oslogstream.m"     # or the skill's reference/oslogstream.m
/tmp/oslogstream <UDID> 10 > /tmp/proto.txt 2>&1
grep -cE '^[0-9]{4}-' /tmp/proto.txt                                       # thousands
grep -oE ' (Default|Info|Debug|Error|Fault) ' /tmp/proto.txt | sort | uniq -c   # MUST show Debug + others
```
A healthy result is thousands of lines with a multi-level distribution (Debug present) and populated
subsystem/category/message. Flat or single-level → a field or flag regressed; go back to probe 2/4.
