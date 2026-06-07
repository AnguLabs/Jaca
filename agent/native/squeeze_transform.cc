#include "squeeze_transform.h"

#include <android/log.h>
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

void JNICALL OnClassFileLoaded(jvmtiEnv* jvmti, JNIEnv* /*jni*/,
                               jclass /*class_being_redefined*/, jobject /*loader*/,
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

bool RegisterExitHook(jvmtiEnv* jvmti, JNIEnv* /*jni*/, jclass clazz,
                      const char* method, const char* signature) {
  char* sig = nullptr;
  if (jvmti->GetClassSignature(clazz, &sig, nullptr) != JVMTI_ERROR_NONE || sig == nullptr) {
    LOGE("GetClassSignature failed");
    return false;
  }
  const std::string desc(sig);
  jvmti->Deallocate(reinterpret_cast<unsigned char*>(sig));

  {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto& specs = g_transforms[desc];
    for (const auto& s : specs) {
      if (s.method == method && s.signature == signature) {
        LOGI("Exit hook already registered for %s.%s%s — skipping", desc.c_str(), method, signature);
        return true;  // idempotent: avoid double-instrumentation on re-attach
      }
    }
    specs.push_back({method, signature});
  }

  jvmti->SetEventNotificationMode(JVMTI_ENABLE, JVMTI_EVENT_CLASS_FILE_LOAD_HOOK, nullptr);
  jvmtiError e = jvmti->RetransformClasses(1, &clazz);
  LOGI("RetransformClasses(%s) -> %d", desc.c_str(), e);
  return e == JVMTI_ERROR_NONE;
}

}  // namespace squeeze
