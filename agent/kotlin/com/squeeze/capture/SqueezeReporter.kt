package com.squeeze.capture

import android.net.LocalServerSocket
import android.os.Process
import android.util.Log
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicLong

/** Owns the localabstract socket to the host; emits one JSON line per transaction. */
object SqueezeReporter {
    private const val TAG = "SqueezeAgent"
    private val seq = AtomicLong(0)
    private val lock = Any()
    @Volatile private var out: OutputStream? = null
    @Volatile private var server: LocalServerSocket? = null

    fun nextId(): Long = seq.incrementAndGet()

    fun listen(socketName: String) {
        try { server?.close() } catch (_: Exception) {}  // unblock any prior serve loop
        Thread({ serve(socketName) }, "squeeze-reporter").apply { isDaemon = true; start() }
    }

    private fun serve(socketName: String) {
        try {
            val srv = LocalServerSocket(socketName)
            server = srv
            Log.i(TAG, "reporter listening on localabstract:$socketName")
            while (true) {
                val client = srv.accept()
                synchronized(lock) { out = client.outputStream }
                emit("{\"type\":\"hello\",\"pid\":${Process.myPid()},\"stage\":4}")
                Log.i(TAG, "host connected")
            }
        } catch (e: Exception) {
            Log.e(TAG, "reporter error", e)
        }
    }

    fun emit(json: String) {
        val o = out ?: return
        try {
            synchronized(lock) {
                o.write((json + "\n").toByteArray(Charsets.UTF_8))
                o.flush()
            }
        } catch (e: Exception) {
            synchronized(lock) { out = null }  // host went away; wait for reconnect
        }
    }
}
