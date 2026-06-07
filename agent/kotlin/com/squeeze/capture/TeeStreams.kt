package com.squeeze.capture

import java.io.FilterInputStream
import java.io.FilterOutputStream
import java.io.InputStream
import java.io.OutputStream

/** Output stream that copies written bytes into the tracker as the request body. */
class RequestStream(out: OutputStream, private val tracker: SqueezeTracker) : FilterOutputStream(out) {
    override fun write(b: Int) {
        out.write(b)
        tracker.appendRequestBody(byteArrayOf(b.toByte()), 0, 1)
    }
    override fun write(b: ByteArray, off: Int, len: Int) {
        out.write(b, off, len)
        tracker.appendRequestBody(b, off, len)
    }
}

/** Input stream that copies read bytes into the tracker as the response body. */
class ResponseStream(input: InputStream, private val tracker: SqueezeTracker) : FilterInputStream(input) {
    override fun read(): Int {
        val b = `in`.read()
        if (b >= 0) tracker.appendResponseByte(b) else tracker.report()
        return b
    }
    override fun read(b: ByteArray, off: Int, len: Int): Int {
        val n = `in`.read(b, off, len)
        if (n > 0) tracker.appendResponseBody(b, off, n) else if (n < 0) tracker.report()
        return n
    }
    override fun close() {
        tracker.report()
        super.close()
    }
}
