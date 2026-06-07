package com.squeeze.agent;

import android.util.Log;

import java.io.File;

import dalvik.system.DexClassLoader;

/**
 * Native entrypoint. Loads the Kotlin capture dex on a SEPARATE class loader
 * whose parent is the bootstrap loader — so its bundled Kotlin stdlib is isolated
 * from (and never shadows) the host app's. Installs the capture handler into the
 * bootstrap trampoline and starts streaming.
 */
public final class SqueezeAgent {
    private static final String TAG = "SqueezeAgent";
    private static volatile boolean started = false;

    /** Called from native: capture dex path + reporter socket name. */
    public static synchronized void attach(String captureDexPath, String socketName) {
        if (started) {
            Log.i(TAG, "attach() ignored — already started");
            return;
        }
        started = true;
        try {
            File optDir = new File(new File(captureDexPath).getParentFile(), "squeeze_opt");
            optDir.mkdirs();
            // Parent = the loader that holds our bootstrap classes (boot). Keeps the
            // capture dex's bundled kotlin.* off the app's class-loader chain.
            ClassLoader parent = SqueezeExitHandler.class.getClassLoader();
            DexClassLoader loader =
                    new DexClassLoader(captureDexPath, optDir.getAbsolutePath(), null, parent);
            Class<?> cls = loader.loadClass("com.squeeze.capture.SqueezeCapture");
            Object capture = cls.getDeclaredConstructor().newInstance();
            SqueezeHooks.handler = (SqueezeExitHandler) capture;
            cls.getMethod("start", String.class).invoke(capture, socketName);
            Log.i(TAG, "Kotlin capture loaded on isolated loader; handler installed");
        } catch (Throwable t) {
            Log.e(TAG, "attach failed", t);
        }
    }

    private SqueezeAgent() {}
}
