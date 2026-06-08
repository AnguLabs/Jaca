#include "squeeze_transform.h"

#include <android/log.h>
#include <atomic>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "slicer/dex_ir.h"
#include "slicer/dex_ir_builder.h"
#include "slicer/instrumentation.h"
#include "slicer/reader.h"
#include "slicer/writer.h"

#define LOG_TAG "SqueezeAgent"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace squeeze {
namespace {

struct MethodSpec {
  std::string method;
  std::string signature;
};

std::mutex g_mutex;
std::unordered_map<std::string, std::vector<MethodSpec>> g_transforms;  // classDesc -> methods

// dex::Writer needs an allocator; back it with JVMTI's allocator so ART owns the
// returned class image buffer.
class JvmtiAllocator : public dex::Writer::Allocator {
 public:
  explicit JvmtiAllocator(jvmtiEnv* jvmti) : jvmti_(jvmti) {}
  void* Allocate(size_t size) override {
    unsigned char* ptr = nullptr;
    jvmti_->Allocate(size, &ptr);
    return ptr;
  }
  void Free(void* ptr) override { jvmti_->Deallocate(reinterpret_cast<unsigned char*>(ptr)); }

 private:
  jvmtiEnv* jvmti_;
};

std::atomic<bool> g_appLoaderSet{false};

// The first app class we instrument (e.g. okhttp3.OkHttpClient) is loaded by the
// app class loader. Stash it in SqueezeHooks so the Kotlin capture can reflectively
// build an okhttp3.Interceptor against the app's okhttp.
void MaybeSetAppLoader(JNIEnv* jni, jobject loader) {
  if (loader == nullptr || g_appLoaderSet.load()) return;
  jclass hooks = jni->FindClass("com/squeeze/agent/SqueezeHooks");
  if (hooks == nullptr) { jni->ExceptionClear(); return; }
  jfieldID fid = jni->GetStaticFieldID(hooks, "appClassLoader", "Ljava/lang/ClassLoader;");
  if (fid == nullptr) { jni->ExceptionClear(); return; }
  jni->SetStaticObjectField(hooks, fid, loader);
  g_appLoaderSet.store(true);
  LOGI("appClassLoader captured from instrumented app class");
}

void JNICALL OnClassFileLoaded(jvmtiEnv* jvmti, JNIEnv* jni,
                               jclass /*class_being_redefined*/, jobject loader,
                               const char* name, jobject /*protection_domain*/,
                               jint class_data_len, const unsigned char* class_data,
                               jint* new_class_data_len, unsigned char** new_class_data) {
  if (name == nullptr) return;
  const std::string desc = std::string("L") + name + ";";

  std::vector<MethodSpec> specs;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_transforms.find(desc);
    if (it == g_transforms.end()) return;
    specs = it->second;
  }
  MaybeSetAppLoader(jni, loader);  // non-null loader == an app class

  dex::Reader reader(class_data, class_data_len);
  auto class_index = reader.FindClassIndex(desc.c_str());
  if (class_index == dex::kNoIndex) {
    LOGE("ClassFileLoadHook: no class index for %s", desc.c_str());
    return;
  }
  reader.CreateClassIr(class_index);
  auto dex_ir = reader.GetIr();

  for (const auto& s : specs) {
    slicer::MethodInstrumenter mi(dex_ir);
    auto tweak = static_cast<slicer::ExitHook::Tweak>(
        slicer::ExitHook::Tweak::ReturnAsObject | slicer::ExitHook::Tweak::PassMethodSignature);
    mi.AddTransformation<slicer::ExitHook>(
        ir::MethodId("Lcom/squeeze/agent/SqueezeHooks;", "onExit"), tweak);
    if (!mi.InstrumentMethod(
            ir::MethodId(desc.c_str(), s.method.c_str(), s.signature.c_str()))) {
      LOGE("InstrumentMethod failed: %s.%s%s", desc.c_str(), s.method.c_str(),
           s.signature.c_str());
    } else {
      LOGI("Instrumented %s.%s%s", desc.c_str(), s.method.c_str(), s.signature.c_str());
    }
  }

  dex::Writer writer(dex_ir);
  JvmtiAllocator allocator(jvmti);
  size_t new_size = 0;
  dex::u1* new_image = writer.CreateImage(&allocator, &new_size);
  *new_class_data_len = static_cast<jint>(new_size);
  *new_class_data = new_image;
  LOGI("Rewrote %s: %d -> %zu bytes", desc.c_str(), class_data_len, new_size);
}

}  // namespace

void InitTransforms(jvmtiEnv* jvmti) {
  jvmtiCapabilities caps;
  memset(&caps, 0, sizeof(caps));
  caps.can_retransform_classes = 1;
  caps.can_retransform_any_class = 1;
  jvmtiError e = jvmti->AddCapabilities(&caps);
  LOGI("AddCapabilities(retransform) -> %d", e);

  jvmtiEventCallbacks callbacks;
  memset(&callbacks, 0, sizeof(callbacks));
  callbacks.ClassFileLoadHook = OnClassFileLoaded;
  jvmti->SetEventCallbacks(&callbacks, sizeof(callbacks));
}

// Returns true if newly added; false if this (method,signature) was already
// registered for the class (idempotent across re-attach).
static bool AddSpec(const std::string& desc, const char* method, const char* signature) {
  std::lock_guard<std::mutex> lock(g_mutex);
  auto& specs = g_transforms[desc];
  for (const auto& s : specs) {
    if (s.method == method && s.signature == signature) return false;
  }
  specs.push_back({method, signature});
  return true;
}

bool RegisterExitHook(jvmtiEnv* jvmti, JNIEnv* /*jni*/, jclass clazz,
                      const char* method, const char* signature) {
  char* sig = nullptr;
  if (jvmti->GetClassSignature(clazz, &sig, nullptr) != JVMTI_ERROR_NONE || sig == nullptr) {
    LOGE("GetClassSignature failed");
    return false;
  }
  const std::string desc(sig);
  jvmti->Deallocate(reinterpret_cast<unsigned char*>(sig));

  if (!AddSpec(desc, method, signature)) {
    LOGI("Exit hook already registered for %s.%s%s — skipping", desc.c_str(), method, signature);
    return true;
  }

  jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_CLASS_FILE_LOAD_HOOK, nullptr);
  jvmtiError e = jvmti->RetransformClasses(1, &clazz);
  LOGI("RetransformClasses(%s) -> %d", desc.c_str(), e);
  return e == JVMTI_ERROR_NONE;
}

bool RegisterExitHookByName(jvmtiEnv* jvmti, JNIEnv* jni, const char* classDescriptor,
                            const char* method, const char* signature) {
  const std::string desc(classDescriptor);
  if (!AddSpec(desc, method, signature)) {
    LOGI("Exit hook already registered for %s.%s%s — skipping", desc.c_str(), method, signature);
    return true;
  }
  jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_CLASS_FILE_LOAD_HOOK, nullptr);

  // Retransform any already-loaded matching class (app classes can't be FindClass'd
  // from the agent; GetLoadedClasses sees all loaders). Future loads hit the hook.
  jint count = 0;
  jclass* classes = nullptr;
  if (jvmti->GetLoadedClasses(&count, &classes) == JVMTI_ERROR_NONE && classes != nullptr) {
    int retransformed = 0;
    for (jint i = 0; i < count; i++) {
      char* sig = nullptr;
      if (jvmti->GetClassSignature(classes[i], &sig, nullptr) == JVMTI_ERROR_NONE && sig != nullptr) {
        if (desc == sig) {
          jvmtiError e = jvmti->RetransformClasses(1, &classes[i]);
          LOGI("RetransformClasses(%s, already-loaded) -> %d", desc.c_str(), e);
          retransformed++;
        }
        jvmti->Deallocate(reinterpret_cast<unsigned char*>(sig));
      }
      jni->DeleteLocalRef(classes[i]);
    }
    jvmti->Deallocate(reinterpret_cast<unsigned char*>(classes));
    LOGI("RegisterExitHookByName(%s): %d already-loaded match(es); hook armed for future loads",
         desc.c_str(), retransformed);
  }
  return true;
}

}  // namespace squeeze
