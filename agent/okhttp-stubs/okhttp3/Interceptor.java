package okhttp3;

import java.io.IOException;

/**
 * COMPILE-ONLY stub of okhttp3.Interceptor — just enough surface for
 * SqueezeOkHttp3Interceptor to compile against. NOT bundled into any dex; at runtime the
 * real okhttp3.Interceptor (from the app) is resolved instead, via the app-parented loader.
 */
public interface Interceptor {
    Response intercept(Chain chain) throws IOException;

    interface Chain {
        Request request();
        Response proceed(Request request) throws IOException;
    }
}
