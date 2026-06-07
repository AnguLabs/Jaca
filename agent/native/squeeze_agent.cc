// Squeeze in-process network capture agent (native JVMTI bootstrap).
//
// Stage 0: prove the attach pipeline — when attached to a debuggable app via
// `cmd activity attach-agent`, Android's ART calls Agent_OnAttach below. We just
// acquire a JVMTI env and log, to confirm we are running inside the target app.
#include <jni.h>
#include <jvmti.h>
#include <android/log.h>
#include <cstring>
#include <unistd.h>

#define LOG_TAG "SqueezeAgent"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

extern "C" JNIEXPORT jint JNICALL
Agent_OnAttach(JavaVM* vm, char* options, void* reserved) {
  LOGI("Agent_OnAttach: pid=%d options=%s", getpid(), options ? options : "(null)");
  jvmtiEnv* jvmti = nullptr;
  jint res = vm->GetEnv(reinterpret_cast<void**>(&jvmti), JVMTI_VERSION_1_2);
  if (res != JNI_OK || jvmti == nullptr) {
    LOGE("Failed to get JVMTI env: %d", res);
    return JNI_OK;  // don't abort the app
  }
  LOGI("JVMTI env acquired: %p — Squeeze agent alive in target process", (void*)jvmti);
  return JNI_OK;
}

extern "C" JNIEXPORT jint JNICALL
Agent_OnLoad(JavaVM* vm, char* options, void* reserved) {
  return Agent_OnAttach(vm, options, reserved);
}

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
  return JNI_VERSION_1_6;
}
