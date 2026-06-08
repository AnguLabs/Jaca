package com.squeeze.capture

import android.util.Log
import com.squeeze.agent.SqueezeHooks
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Method
import java.lang.reflect.Proxy
import java.util.zip.GZIPInputStream

/**
 * Injects a capture interceptor into okhttp3 clients. We can't compile against the
 * app's okhttp (it's on the app class loader, not ours), so the interceptor is a
 * dynamic Proxy of okhttp3.Interceptor and all okhttp calls go through reflection.
 *
 * Hooked via SqueezeHooks on okhttp3.OkHttpClient.networkInterceptors(): the exit
 * hook returns a list with our interceptor prepended, so it runs for every call.
 */
object OkHttpHook {
    private const val TAG = "SqueezeAgent"
    private const val BODY_PEEK = 512L * 1024

    @Volatile private var interceptor: Any? = null
    @Volatile private var failed = false

    /** Returns a new list with our interceptor first, or the original on any failure. */
    fun inject(existing: List<*>): List<*> {
        val ic = ensureInterceptor() ?: return existing
        // Avoid double-injecting if okhttp calls this twice for one chain.
        if (existing.any { it === ic }) return existing
        val out = ArrayList<Any?>(existing.size + 1)
        out.add(ic)
        out.addAll(existing)
        return out
    }

    private fun ensureInterceptor(): Any? {
        interceptor?.let { return it }
        if (failed) return null
        synchronized(this) {
            interceptor?.let { return it }
            try {
                val loader = SqueezeHooks.appClassLoader ?: Thread.currentThread().contextClassLoader
                val interceptorCls = Class.forName("okhttp3.Interceptor", false, loader)
                val proxy = Proxy.newProxyInstance(loader, arrayOf(interceptorCls), Handler())
                interceptor = proxy
                Log.i(TAG, "okhttp3 capture interceptor installed")
                return proxy
            } catch (t: Throwable) {
                failed = true
                Log.e(TAG, "okhttp3 interceptor build failed: $t")
                return null
            }
        }
    }

    private class Handler : InvocationHandler {
        override fun invoke(proxy: Any, method: Method, args: Array<out Any?>?): Any? {
            if (method.name == "intercept" && args != null && args.isNotEmpty() && args[0] != null) {
                return intercept(args[0]!!)
            }
            return when (method.name) {
                "hashCode" -> System.identityHashCode(proxy)
                "equals" -> proxy === args?.getOrNull(0)
                "toString" -> "SqueezeOkHttpInterceptor"
                else -> null
            }
        }

        private fun intercept(chain: Any): Any {
            val chainCls = chain.javaClass
            val request = chainCls.getMethod("request").invoke(chain)
            // proceed() MUST run and its result MUST be returned, whatever else fails.
            val response = chainCls.getMethod("proceed", request.javaClass).invoke(chain, request)
            try { record(request, response) } catch (t: Throwable) { /* never break the call */ }
            return response
        }

        private fun record(request: Any, response: Any) {
            val reqCls = request.javaClass
            val url = reqCls.getMethod("url").invoke(request).toString()
            val tracker = SqueezeTracker(url)
            (reqCls.getMethod("method").invoke(request) as? String)?.let { tracker.setMethod(it) }
            tracker.setRequestHeaders(headers(reqCls.getMethod("headers").invoke(request)))

            val respCls = response.javaClass
            val code = respCls.getMethod("code").invoke(response) as Int
            val respHeaders = headers(respCls.getMethod("headers").invoke(response))
            tracker.onResponse(code, respHeaders)

            try {
                val peek = respCls.getMethod("peekBody", java.lang.Long.TYPE).invoke(response, BODY_PEEK)
                var bytes = peek.javaClass.getMethod("bytes").invoke(peek) as ByteArray
                if (isGzip(respHeaders)) bytes = gunzip(bytes)
                tracker.appendResponseBody(bytes, 0, bytes.size)
            } catch (t: Throwable) { /* body optional */ }

            tracker.report()
        }

        @Suppress("UNCHECKED_CAST")
        private fun headers(headers: Any?): Map<String, List<String>>? {
            headers ?: return null
            return try {
                headers.javaClass.getMethod("toMultimap").invoke(headers) as? Map<String, List<String>>
            } catch (t: Throwable) { null }
        }

        private fun isGzip(headers: Map<String, List<String>>?): Boolean {
            val v = headers?.entries?.firstOrNull { it.key.equals("Content-Encoding", true) }?.value
            return v?.any { it.contains("gzip", true) } == true
        }

        private fun gunzip(data: ByteArray): ByteArray = try {
            GZIPInputStream(data.inputStream()).readBytes()
        } catch (t: Throwable) { data }  // truncated/partial peek — keep what we have
    }
}
