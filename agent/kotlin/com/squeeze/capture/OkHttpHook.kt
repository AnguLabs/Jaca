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

        // Mirrors AOSP's OkHttp3Interceptor: track the request up-front (best-effort),
        // run proceed(), and on failure record the error and RETHROW the real exception
        // so okhttp handles it normally (a cancel/IO error must not crash the app).
        private fun intercept(chain: Any): Any {
            val chainCls = chain.javaClass
            val request = invokeUnwrapped { chainCls.getMethod("request").invoke(chain) }
            val tracker = try { startTracker(request) } catch (t: Throwable) { null }

            val response: Any
            try {
                response = invokeUnwrapped { chainCls.getMethod("proceed", request.javaClass).invoke(chain, request) }
            } catch (e: Throwable) {
                try { tracker?.setError(e.toString()); tracker?.report() } catch (ignored: Throwable) {}
                throw e
            }

            try { tracker?.let { recordResponse(it, response) } } catch (t: Throwable) { /* never break the call */ }
            return response
        }

        /** Runs a reflective call, rethrowing the real exception instead of the
         *  InvocationTargetException wrapper that Method.invoke would otherwise leak. */
        private inline fun invokeUnwrapped(block: () -> Any?): Any {
            try {
                return block()!!
            } catch (e: java.lang.reflect.InvocationTargetException) {
                throw e.targetException ?: e
            }
        }

        /** Records the request (method/url/headers) and returns the tracker, so the
         *  transaction is emitted even if the call later fails/cancels. */
        private fun startTracker(request: Any): SqueezeTracker {
            val reqCls = request.javaClass
            val url = reqCls.getMethod("url").invoke(request).toString()
            val tracker = SqueezeTracker(url)
            (reqCls.getMethod("method").invoke(request) as? String)?.let { tracker.setMethod(it) }
            tracker.setRequestHeaders(headers(reqCls.getMethod("headers").invoke(request)))
            return tracker
        }

        private fun recordResponse(tracker: SqueezeTracker, response: Any) {
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
