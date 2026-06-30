package com.squeeze.capture;

import com.squeeze.agent.SqueezeOkHttpDelegate;
import okhttp3.Interceptor;
import okhttp3.Response;

import java.io.IOException;

/**
 * The REAL okhttp3 network interceptor (compiled against the okhttp stubs; bundled in the
 * capture dex). It is loaded on a child of the app class loader so this class binds to the
 * app's okhttp3.Interceptor, and — being a real class, not a {@code java.lang.reflect.Proxy} —
 * its {@code intercept} is invoked directly. That matters: a Proxy re-wraps any thrown checked
 * exception as UndeclaredThrowableException when the proxied method lacks a {@code throws}
 * clause (R8 strips okhttp's), which slipped a cancelled call's IOException past okhttp's
 * {@code catch (IOException)} on the async dispatcher and crashed the app. Here the IOException
 * from {@link #delegate} propagates unchanged, so okhttp handles the cancel/failure normally.
 *
 * All real work happens in the Kotlin capture handler, reached through the bootstrap
 * {@link SqueezeOkHttpDelegate} bridge (shared across loaders).
 */
public final class SqueezeOkHttp3Interceptor implements Interceptor {
    private final SqueezeOkHttpDelegate delegate;

    public SqueezeOkHttp3Interceptor(SqueezeOkHttpDelegate delegate) {
        this.delegate = delegate;
    }

    @Override
    public Response intercept(Chain chain) throws IOException {
        return (Response) delegate.intercept(chain);
    }
}
