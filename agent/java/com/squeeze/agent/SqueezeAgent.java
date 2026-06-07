package com.squeeze.agent;

import android.util.Log;

/**
 * In-process agent entrypoint, invoked from the native JVMTI agent after the dex
 * is added to the bootstrap class loader and the hooks are installed. Starts the
 * reporter socket that streams captured transactions to the host (Squeeze).
 */
public final class SqueezeAgent {
    private static final String TAG = "SqueezeAgent";
    private static volatile boolean started = false;

    /** Called from native. {@code options} is the localabstract socket name. */
    public static synchronized void attach(String options) {
        if (started) {
            Log.i(TAG, "attach() ignored — already started");
            return;
        }
        started = true;
        final String socketName = (options == null || options.isEmpty()) ? "squeeze_agent" : options;
        Log.i(TAG, "Java attach(); reporter socket=localabstract:" + socketName);
        SqueezeReporter.INSTANCE.listen(socketName);
    }

    private SqueezeAgent() {}
}
