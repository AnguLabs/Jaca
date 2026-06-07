package com.squeeze.agent;

import android.util.Log;

import com.squeeze.agent.net.SqueezeTracker;
import com.squeeze.agent.net.TrackedHttpsURLConnection;

import javax.net.ssl.HttpsURLConnection;

/**
 * Dispatch target for instrumented method exits. slicer rewrites hooked methods
 * to call {@link #onExit} on return, passing the method signature and the return
 * value; whatever we return replaces the original return value.
 *
 * For URL.openConnection() we return a tracking wrapper that records the
 * request/response in-process (no proxy, no CA) and streams it to the host.
 */
public final class SqueezeHooks {
    private static final String TAG = "SqueezeAgent";

    public static Object onExit(String methodSignature, Object returnObject) {
        try {
            if (returnObject instanceof TrackedHttpsURLConnection) {
                return returnObject;  // already wrapped
            }
            if (returnObject instanceof HttpsURLConnection) {
                HttpsURLConnection c = (HttpsURLConnection) returnObject;
                return new TrackedHttpsURLConnection(c, new SqueezeTracker(c.getURL().toString()));
            }
        } catch (Throwable t) {
            Log.e(TAG, "onExit wrap error", t);
        }
        return returnObject;
    }

    private SqueezeHooks() {}
}
