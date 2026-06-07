package com.squeeze.agent;

import android.util.Log;

/**
 * Dispatch target for instrumented method exits. slicer rewrites hooked methods
 * to call {@link #onExit} on return, passing the method signature and the return
 * value; whatever we return replaces the original return value.
 *
 * Stage 2: just log that the hook fired (proving the bytecode rewrite works) and
 * return the value unchanged. Stage 3 routes by signature to wrap/inject capture.
 */
public final class SqueezeHooks {
    private static final String TAG = "SqueezeAgent";

    public static Object onExit(String methodSignature, Object returnObject) {
        Log.i(TAG, "onExit HOOK FIRED: " + methodSignature + " -> "
                + (returnObject == null ? "null" : returnObject.getClass().getName()));
        return returnObject;
    }

    private SqueezeHooks() {}
}
