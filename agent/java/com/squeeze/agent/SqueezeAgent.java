package com.squeeze.agent;

import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.util.Log;

import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

/**
 * In-process agent entrypoint, invoked from the native JVMTI agent after the dex
 * is added to the app's class loader. Stage 1: open a {@code localabstract}
 * socket and stream a hello line so the host (Squeeze) can confirm we're running
 * inside the target app's process. Later stages stream captured network events.
 */
public final class SqueezeAgent {
    private static final String TAG = "SqueezeAgent";
    private static volatile boolean started = false;

    /** Called from native. {@code options} is the localabstract socket name. */
    public static synchronized void attach(String options) {
        if (started) {
            Log.i(TAG, "attach() ignored — already started");
            return;
        }
        started = true;
        final String socketName = (options == null || options.isEmpty()) ? "squeeze_agent" : options;
        Log.i(TAG, "Java attach(); socket=localabstract:" + socketName);
        Thread t = new Thread(() -> serve(socketName), "squeeze-agent");
        t.setDaemon(true);
        t.start();
        selfTestHook();
    }

    /** Stage 2 self-test: call a hooked method so onExit fires regardless of app traffic. */
    private static void selfTestHook() {
        try {
            java.net.URLConnection c = new java.net.URL("http://127.0.0.1/").openConnection();
            Log.i(TAG, "self-test openConnection -> " + c.getClass().getName());
        } catch (Exception e) {
            Log.i(TAG, "self-test openConnection threw: " + e);
        }
    }

    private static void serve(String socketName) {
        try {
            LocalServerSocket server = new LocalServerSocket(socketName);
            Log.i(TAG, "listening on localabstract:" + socketName);
            while (true) {
                LocalSocket client = server.accept();
                try {
                    OutputStream os = client.getOutputStream();
                    String hello = "{\"type\":\"hello\",\"pid\":" + android.os.Process.myPid()
                            + ",\"agent\":\"squeeze\",\"stage\":1}\n";
                    os.write(hello.getBytes(StandardCharsets.UTF_8));
                    os.flush();
                    Log.i(TAG, "sent hello to host");
                } catch (Exception e) {
                    Log.e(TAG, "client error", e);
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "serve error", e);
        }
    }

    private SqueezeAgent() {}
}
