// Squeeze in-process network capture agent (native JVMTI bootstrap).
//
// On attach to a debuggable app via `cmd activity attach-agent <pid> <so>=<opts>`,
// ART calls Agent_OnAttach. We:
//   1. acquire a JVMTI env,
//   2. add our Kotlin/Java agent dex to the system class loader search,
//   3. call com.squeeze.agent.SqueezeAgent.attach(socketName) via JNI.
//
// `options` (the part after '=' in the attach spec) is "<dexPath>,<socketName>".
#include <jni.h>
#include <jvmti.h>
#include <android/log.h>
#include <cstring>
#include <string>
#include <unistd.h>

#define LOG_TAG "SqueezeAgent"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

jint AttachAgent(JavaVM* vm, char* options) {
  LOGI("Agent_OnAttach: pid=%d options=%s", getpid(), options ? options : "(null)");

  jvmtiEnv* jvmti = nullptr;
  if (vm->GetEnv(reinterpret_cast<void**>(&jvmti), JVMTI_VERSION_1_2) != JNI_OK || jvmti == nullptr) {
    LOGE("Failed to get JVMTI env");
    return JNI_OK;
  }

  // Parse "<dexPath>,<socketName>".
  std::string opts = options ? options : "";
  std::string dexPath, socketName = "squeeze_agent";
  auto comma = opts.find(',');
  if (comma != std::string::npos) {
    dexPath = opts.substr(0, comma);
    socketName = opts.substr(comma + 1);
  } else {
    dexPath = opts;
  }

  if (!dexPath.empty()) {
    jvmtiError err = jvmti->AddToSystemClassLoaderSearch(dexPath.c_str());
    LOGI("AddToSystemClassLoaderSearch(%s) -> %d", dexPath.c_str(), err);
    if (err != JVMTI_ERROR_NONE) {
      LOGE("Failed to add dex to classpath: %d", err);
      return JNI_OK;
    }
  }

  JNIEnv* jni = nullptr;
  if (vm->GetEnv(reinterpret_cast<void**>(&jni), JNI_VERSION_1_6) != JNI_OK || jni == nullptr) {
    LOGE("Failed to get JNI env");
    return JNI_OK;
  }

  // AddToSystemClassLoaderSearch puts our dex on the *system* class loader, but a
  // FindClass from an agent (no Java frame) resolves against the bootstrap loader.
  // So load our class explicitly via ClassLoader.getSystemClassLoader().loadClass().
  jclass clClass = jni->FindClass("java/lang/ClassLoader");
  jmethodID getSys = jni->GetStaticMethodID(clClass, "getSystemClassLoader", "()Ljava/lang/ClassLoader;");
  jmethodID loadClass = jni->GetMethodID(clClass, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
  jobject sysLoader = jni->CallStaticObjectMethod(clClass, getSys);
  jstring clsName = jni->NewStringUTF("com.squeeze.agent.SqueezeAgent");
  jclass cls = reinterpret_cast<jclass>(jni->CallObjectMethod(sysLoader, loadClass, clsName));
  jni->DeleteLocalRef(clsName);
  if (cls == nullptr || jni->ExceptionCheck()) {
    if (jni->ExceptionCheck()) { jni->ExceptionDescribe(); jni->ExceptionClear(); }
    LOGE("Could not load com.squeeze.agent.SqueezeAgent via system class loader");
    return JNI_OK;
  }
  jmethodID attach = jni->GetStaticMethodID(cls, "attach", "(Ljava/lang/String;)V");
  if (attach == nullptr) {
    if (jni->ExceptionCheck()) jni->ExceptionClear();
    LOGE("Could not find SqueezeAgent.attach(String)");
    return JNI_OK;
  }
  jstring arg = jni->NewStringUTF(socketName.c_str());
  jni->CallStaticVoidMethod(cls, attach, arg);
  if (jni->ExceptionCheck()) {
    jni->ExceptionDescribe();
    jni->ExceptionClear();
    LOGE("SqueezeAgent.attach threw");
  } else {
    LOGI("SqueezeAgent.attach invoked (socket=%s)", socketName.c_str());
  }
  jni->DeleteLocalRef(arg);
  return JNI_OK;
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Agent_OnAttach(JavaVM* vm, char* options, void* reserved) {
  return AttachAgent(vm, options);
}

extern "C" JNIEXPORT jint JNICALL
Agent_OnLoad(JavaVM* vm, char* options, void* reserved) {
  return AttachAgent(vm, options);
}

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
  return JNI_VERSION_1_6;
}
