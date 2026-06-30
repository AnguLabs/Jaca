package com.squeeze.agent;

import java.io.IOException;

/**
 * Bootstrap-loader bridge between the real okhttp3 interceptor class and the Kotlin capture
 * handler. The interceptor class (SqueezeOkHttp3Interceptor) is loaded on a child of the APP
 * loader so it binds to the app's okhttp3; the capture logic lives on the isolated capture
 * loader. Both can see this interface (it's on the bootstrap loader), so it carries the call
 * across the loader boundary. Declares {@code throws IOException} so a cancelled/failed call's
 * IOException propagates to okhttp unchanged — pure Java, nothing to shadow.
 */
public interface SqueezeOkHttpDelegate {
    Object intercept(Object chain) throws IOException;
}
