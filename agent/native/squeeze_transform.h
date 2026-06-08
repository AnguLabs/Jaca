#pragma once
#include <jni.h>
#include <jvmti.h>

namespace squeeze {

// Sets retransform capabilities + the ClassFileLoadHook callback. Call once.
void InitTransforms(jvmtiEnv* jvmti);

// Registers an exit hook on clazz.method+signature: the method is bytecode-
// rewritten (via slicer) so on return it calls
// com.squeeze.agent.SqueezeHooks.onExit(String methodSignature, Object ret)
// and uses its return value. Triggers RetransformClasses for already-loaded
// classes. Returns true on success.
bool RegisterExitHook(jvmtiEnv* jvmti, JNIEnv* jni, jclass clazz,
                      const char* method, const char* signature);

// Like RegisterExitHook but for a class we can't FindClass (e.g. an app class on
// the app loader such as okhttp3.OkHttpClient). Registers the transform by
// descriptor, retransforms any already-loaded matching classes, and relies on the
// ClassFileLoadHook for future loads. `classDescriptor` is "Lokhttp3/OkHttpClient;".
bool RegisterExitHookByName(jvmtiEnv* jvmti, JNIEnv* jni, const char* classDescriptor,
                            const char* method, const char* signature);

}  // namespace squeeze
