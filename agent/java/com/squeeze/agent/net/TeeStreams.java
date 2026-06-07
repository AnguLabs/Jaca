package com.squeeze.agent.net;

import java.io.FilterInputStream;
import java.io.FilterOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/** Stream wrappers that copy bytes into a SqueezeTracker as they flow. */
final class TeeStreams {

    static final class RequestStream extends FilterOutputStream {
        private final SqueezeTracker tracker;
        RequestStream(OutputStream out, SqueezeTracker t) { super(out); this.tracker = t; }
        @Override public void write(int b) throws IOException {
            out.write(b);
            tracker.appendRequestBody(new byte[]{(byte) b}, 0, 1);
        }
        @Override public void write(byte[] b, int off, int len) throws IOException {
            out.write(b, off, len);
            tracker.appendRequestBody(b, off, len);
        }
    }

    static final class ResponseStream extends FilterInputStream {
        private final SqueezeTracker tracker;
        ResponseStream(InputStream in, SqueezeTracker t) { super(in); this.tracker = t; }
        @Override public int read() throws IOException {
            int b = in.read();
            if (b >= 0) tracker.appendResponseBody(b);
            else tracker.report();
            return b;
        }
        @Override public int read(byte[] b, int off, int len) throws IOException {
            int n = in.read(b, off, len);
            if (n > 0) tracker.appendResponseBody(b, off, n);
            else if (n < 0) tracker.report();
            return n;
        }
        @Override public void close() throws IOException {
            tracker.report();
            super.close();
        }
    }

    private TeeStreams() {}
}
