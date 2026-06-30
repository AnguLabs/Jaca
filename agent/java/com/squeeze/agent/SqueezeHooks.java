package com.squeeze.agent;

/**
 * The slicer ExitHook trampoline target. Lives on the BOOTSTRAP class loader (so
 * instrumented boot classes like java.net.URL can resolve it) and must stay pure
 * Java — no Kotlin stdlib here, or it would shadow the host app's. All real work
 * is delegated to the Kotlin capture handler installed on a separate loader.
 */
public final class SqueezeHooks {
    public static volatile SqueezeExitHandler handler;

    /** Class loader of the first instrumented app class (e.g. okhttp3.OkHttpClient).
     *  Set from native; used by the capture to build an okhttp3.Interceptor by reflection. */
    public static volatile ClassLoader appClassLoader;

    /** Filesystem path of the capture dex. Set from {@link SqueezeAgent#attach}; the okhttp3
     *  capture loads the real interceptor class from it on a child of {@link #appClassLoader}. */
    public static volatile String captureDexPath;

    public static Object onExit(String methodSignature, Object returnObject) {
        SqueezeExitHandler h = handler;
        if (h == null) return returnObject;
        try {
            return h.onExit(methodSignature, returnObject);
        } catch (Throwable t) {
            return returnObject;  // never let capture break the app
        }
    }

    private SqueezeHooks() {}
}
