package com.squeeze.agent;

import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.util.Log;

import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Owns the localabstract socket to the host and emits one JSON line per network
 * transaction. Single connection (Squeeze); if none is connected, events are
 * dropped.
 */
public final class SqueezeReporter {
    private static final String TAG = "SqueezeAgent";
    public static final SqueezeReporter INSTANCE = new SqueezeReporter();

    private final AtomicLong seq = new AtomicLong(0);
    private final Object lock = new Object();
    private volatile OutputStream out;

    private SqueezeReporter() {}

    public long nextId() { return seq.incrementAndGet(); }

    public void listen(String socketName) {
        Thread t = new Thread(() -> serve(socketName), "squeeze-reporter");
        t.setDaemon(true);
        t.start();
    }

    private void serve(String socketName) {
        try {
            LocalServerSocket server = new LocalServerSocket(socketName);
            Log.i(TAG, "reporter listening on localabstract:" + socketName);
            while (true) {
                LocalSocket client = server.accept();
                synchronized (lock) { out = client.getOutputStream(); }
                emitRaw("{\"type\":\"hello\",\"pid\":" + android.os.Process.myPid() + ",\"stage\":3}");
                Log.i(TAG, "host connected");
            }
        } catch (Exception e) {
            Log.e(TAG, "reporter serve error", e);
        }
    }

    /** Emit a JSON object line (no trailing newline needed). */
    public void emit(String json) {
        emitRaw(json);
    }

    private void emitRaw(String json) {
        OutputStream o = out;
        if (o == null) return;
        try {
            synchronized (lock) {
                o.write((json + "\n").getBytes(StandardCharsets.UTF_8));
                o.flush();
            }
        } catch (Exception e) {
            synchronized (lock) { out = null; }  // host went away; wait for reconnect
        }
    }
}
