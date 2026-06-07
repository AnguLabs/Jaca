package com.squeeze.capture

import android.util.Log
import com.squeeze.agent.SqueezeExitHandler
import javax.net.ssl.HttpsURLConnection

/**
 * Kotlin capture handler, loaded on an isolated class loader (its own bundled
 * Kotlin stdlib, so it never shadows the host app's). Implements the bootstrap
 * Java bridge interface; [onExit] wraps connections returned by hooked methods.
 */
class SqueezeCapture : SqueezeExitHandler {

    fun start(socketName: String?) {
        val name = if (socketName.isNullOrEmpty()) "squeeze_agent" else socketName
        Log.i(TAG, "Kotlin capture start; socket=localabstract:$name")
        SqueezeReporter.listen(name)
    }

    override fun onExit(methodSignature: String?, returnObject: Any?): Any? {
        try {
            if (returnObject is TrackedHttpsURLConnection) return returnObject
            if (returnObject is HttpsURLConnection) {
                return TrackedHttpsURLConnection(returnObject, SqueezeTracker(returnObject.url.toString()))
            }
        } catch (t: Throwable) {
            Log.e(TAG, "onExit wrap error", t)
        }
        return returnObject
    }

    companion object { const val TAG = "SqueezeAgent" }
}
