package com.squeeze.capture

import android.util.Log
import com.squeeze.agent.SqueezeHooks
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Method
import java.lang.reflect.Proxy
import java.util.zip.GZIPInputStream

/**
 * Injects a capture interceptor into okhttp clients (okhttp3 and okhttp2/squareup).
 * We can't compile against the app's okhttp (it's on the app class loader, not ours),
 * so the interceptor is a dynamic Proxy of the relevant Interceptor interface and all
 * okhttp calls go through reflection.
 *
 * Hooked via SqueezeHooks on OkHttpClient.networkInterceptors(): the exit hook returns
 * a list with our interceptor prepended, so it runs for every call. okhttp3 and okhttp2
 * expose the same chain methods (request()/proceed()) so one reflective Handler serves
 * both; only the Interceptor interface type differs.
 */
object OkHttpHook {
    private const val TAG = "SqueezeAgent"
    private const val BODY_PEEK = 1024L * 1024   // cap captured bodies at 1 MB

    private val interceptors = java.util.concurrent.ConcurrentHashMap<String, Any>()
    private val failed = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    /** Returns a list with our interceptor first, or the original on any failure.
     *  [ifaceName] is the okhttp Interceptor interface to proxy (okhttp3 vs squareup). */
    fun inject(existing: List<*>, ifaceName: String): List<*> {
        val ic = ensureInterceptor(ifaceName) ?: return existing
        if (existing.any { it === ic }) return existing
        // okhttp2's networkInterceptors() returns the live mutable list (add in place);
        // okhttp3's is immutable, so fall back to a new prepended list.
        return try {
            @Suppress("UNCHECKED_CAST")
            (existing as MutableList<Any?>).add(0, ic)
            existing
        } catch (t: Throwable) {
            val out = ArrayList<Any?>(existing.size + 1)
            out.add(ic)
            out.addAll(existing)
            out
        }
    }

    private fun ensureInterceptor(ifaceName: String): Any? {
        interceptors[ifaceName]?.let { return it }
        if (failed.contains(ifaceName)) return null
        synchronized(this) {
            interceptors[ifaceName]?.let { return it }
            return try {
                val loader = SqueezeHooks.appClassLoader ?: Thread.currentThread().contextClassLoader
                val interceptorCls = Class.forName(ifaceName, false, loader)
                val proxy = Proxy.newProxyInstance(loader, arrayOf(interceptorCls), Handler())
                interceptors[ifaceName] = proxy
                Log.i(TAG, "$ifaceName capture interceptor installed")
                proxy
            } catch (t: Throwable) {
                failed.add(ifaceName)
                Log.e(TAG, "$ifaceName interceptor build failed: $t")
                null
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

        // Mirrors AOSP's OkHttp{3,2}Interceptor: track the request up-front (best-effort),
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

        /** Records the request (method/url/headers/body) and returns the tracker, so the
         *  transaction is emitted even if the call later fails/cancels. */
        private fun startTracker(request: Any): SqueezeTracker {
            val reqCls = request.javaClass
            val url = reqCls.getMethod("url").invoke(request).toString()
            val tracker = SqueezeTracker(url)
            (reqCls.getMethod("method").invoke(request) as? String)?.let { tracker.setMethod(it) }
            tracker.setRequestHeaders(headers(reqCls.getMethod("headers").invoke(request)))
            captureRequestBody(request, tracker)
            return tracker
        }

        /** Capture the request body by writing it into a fresh okio Buffer — exactly what
         *  AOSP does (write the RequestBody to a sink). We only do this for a known,
         *  bounded length and never for one-shot/duplex bodies, so we can't consume a
         *  body the app still needs to send. */
        private fun captureRequestBody(request: Any, tracker: SqueezeTracker) {
            try {
                val body = request.javaClass.getMethod("body").invoke(request) ?: return
                if (boolMethod(body, "isDuplex") || boolMethod(body, "isOneShot")) return
                val len = longMethod(body, "contentLength")
                if (len !in 1..BODY_PEEK) return   // skip empty / unknown / oversized
                val writeTo = body.javaClass.methods.firstOrNull {
                    it.name == "writeTo" && it.parameterTypes.size == 1
                } ?: return
                // The single param is okio.BufferedSink; the concrete Buffer that implements
                // it lives next to it (okio.Buffer, or okhttp2's repackaged equivalent).
                val sinkType = writeTo.parameterTypes[0]
                val bufferCls = Class.forName(sinkType.name.replace("BufferedSink", "Buffer"),
                                              false, sinkType.classLoader)
                val buffer = bufferCls.getConstructor().newInstance()
                writeTo.invoke(body, buffer)
                val bytes = bufferCls.getMethod("readByteArray").invoke(buffer) as ByteArray
                tracker.appendRequestBody(bytes, 0, bytes.size)
            } catch (t: Throwable) { /* request body is best-effort */ }
        }

        private fun recordResponse(tracker: SqueezeTracker, response: Any) {
            val respCls = response.javaClass
            val code = respCls.getMethod("code").invoke(response) as Int
            val respHeaders = headers(respCls.getMethod("headers").invoke(response))
            tracker.onResponse(code, respHeaders)

            // peekBody(n) does source.request(n), which BLOCKS until n bytes arrive or
            // the stream ends. On a streaming response (SSE/gRPC/long-poll) that would
            // stall the app from receiving its own body, so skip the eager peek there
            // and bound it by Content-Length when known. (okhttp2 has no peekBody, so the
            // getMethod below throws and the body is simply skipped — that's fine.)
            if (!isStreaming(respHeaders)) {
                try {
                    val len = contentLength(respHeaders)
                    if (len != 0L) {
                        val peekN = if (len in 1..BODY_PEEK) len else BODY_PEEK
                        val peek = respCls.getMethod("peekBody", java.lang.Long.TYPE).invoke(response, peekN)
                        var bytes = peek.javaClass.getMethod("bytes").invoke(peek) as ByteArray
                        if (isGzip(respHeaders)) bytes = gunzip(bytes)
                        tracker.appendResponseBody(bytes, 0, bytes.size)
                    }
                } catch (t: Throwable) { /* body optional */ }
            }

            tracker.report()
        }

        private fun boolMethod(obj: Any, name: String): Boolean = try {
            obj.javaClass.getMethod(name).invoke(obj) as? Boolean ?: false
        } catch (t: Throwable) { false }

        private fun longMethod(obj: Any, name: String): Long = try {
            (obj.javaClass.getMethod(name).invoke(obj) as? Long) ?: -1L
        } catch (t: Throwable) { -1L }

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

        /** Content types that never end (or shouldn't be eagerly buffered) — peeking
         *  these would block the app's own read. */
        private fun isStreaming(headers: Map<String, List<String>>?): Boolean {
            val ct = header(headers, "Content-Type")?.lowercase() ?: return false
            return ct.startsWith("text/event-stream") ||
                ct.startsWith("application/grpc") ||
                ct.contains("x-mixed-replace")
        }

        private fun contentLength(headers: Map<String, List<String>>?): Long =
            header(headers, "Content-Length")?.toLongOrNull() ?: -1L

        private fun header(headers: Map<String, List<String>>?, name: String): String? =
            headers?.entries?.firstOrNull { it.key.equals(name, true) }?.value?.firstOrNull()

        private fun gunzip(data: ByteArray): ByteArray = try {
            GZIPInputStream(data.inputStream()).readBytes()
        } catch (t: Throwable) { data }  // truncated/partial peek — keep what we have
    }
}
