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
    private static volatile Object captureInstance;  // com.squeeze.capture.SqueezeCapture

    /** Called from native: capture dex path + reporter socket name. */
    public static synchronized void attach(String captureDexPath, String socketName) {
        try {
            if (captureInstance != null) {
                // Re-attach: capture is already loaded + hooks installed; just point
                // the reporter at the new host socket.
                captureInstance.getClass().getMethod("start", String.class)
                        .invoke(captureInstance, socketName);
                Log.i(TAG, "re-attach: reporter re-pointed to " + socketName);
                return;
            }
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
            captureInstance = capture;
            Log.i(TAG, "Kotlin capture loaded on isolated loader; handler installed");
        } catch (Throwable t) {
            Log.e(TAG, "attach failed", t);
        }
    }

    private SqueezeAgent() {}
}
