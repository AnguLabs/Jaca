package com.squeeze.agent.net;

import com.squeeze.agent.SqueezeReporter;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.util.List;
import java.util.Map;

/**
 * Accumulates one HTTP transaction and emits it as a JSON line to the host.
 * Bodies are captured up to a cap. Thread-safe enough for a single connection's
 * lifecycle (request then response).
 */
public final class SqueezeTracker {
    private static final int BODY_CAP = 256 * 1024;

    private final long id = SqueezeReporter.INSTANCE.nextId();
    private final String url;
    private volatile String method = "GET";
    private final long startedAtMs = System.currentTimeMillis();
    private volatile long responseAtMs = 0;
    private volatile boolean reported = false;

    private Map<String, List<String>> requestHeaders;
    private final ByteArrayOutputStream requestBody = new ByteArrayOutputStream();
    private int statusCode = 0;
    private Map<String, List<String>> responseHeaders;
    private final ByteArrayOutputStream responseBody = new ByteArrayOutputStream();
    private String error;
    private String[] callStack;

    public SqueezeTracker(String url) {
        this.url = url;
        this.callStack = captureStack();
    }

    public void setMethod(String m) { if (m != null) method = m; }
    public void setRequestHeaders(Map<String, List<String>> h) { requestHeaders = h; }

    public void appendRequestBody(byte[] b, int off, int len) {
        synchronized (requestBody) {
            int room = BODY_CAP - requestBody.size();
            if (room > 0) requestBody.write(b, off, Math.min(len, room));
        }
    }

    public void onResponse(int code, Map<String, List<String>> headers) {
        if (responseAtMs == 0) responseAtMs = System.currentTimeMillis();
        statusCode = code;
        responseHeaders = headers;
    }

    public void appendResponseBody(int b) {
        synchronized (responseBody) { if (responseBody.size() < BODY_CAP) responseBody.write(b); }
    }

    public void appendResponseBody(byte[] b, int off, int len) {
        synchronized (responseBody) {
            int room = BODY_CAP - responseBody.size();
            if (room > 0) responseBody.write(b, off, Math.min(len, room));
        }
    }

    public void setError(String e) { error = e; }

    public synchronized void report() {
        if (reported) return;
        reported = true;
        try {
            JSONObject o = new JSONObject();
            o.put("type", "txn");
            o.put("id", String.valueOf(id));
            o.put("method", method);
            o.put("url", url);
            o.put("startedAt", startedAtMs / 1000.0);
            if (responseAtMs > 0) o.put("responseAt", responseAtMs / 1000.0);
            o.put("finishedAt", System.currentTimeMillis() / 1000.0);
            o.put("status", statusCode);
            if (error != null) o.put("error", error);
            o.put("requestHeaders", headersToJson(requestHeaders));
            o.put("responseHeaders", headersToJson(responseHeaders));
            o.put("requestBody", bodyToString(requestBody));
            o.put("responseBody", bodyToString(responseBody));
            o.put("requestSize", requestBody.size());
            o.put("responseSize", responseBody.size());
            if (callStack != null) {
                JSONArray cs = new JSONArray();
                for (String s : callStack) cs.put(s);
                o.put("callStack", cs);
            }
            SqueezeReporter.INSTANCE.emit(o.toString());
        } catch (Throwable t) {
            // never let reporting break the app
        }
    }

    private static JSONObject headersToJson(Map<String, List<String>> headers) {
        JSONObject obj = new JSONObject();
        if (headers == null) return obj;
        try {
            for (Map.Entry<String, List<String>> e : headers.entrySet()) {
                String k = e.getKey() == null ? "" : e.getKey();
                List<String> v = e.getValue();
                obj.put(k, v == null ? "" : String.join(", ", v));
            }
        } catch (Throwable ignored) {}
        return obj;
    }

    private static String bodyToString(ByteArrayOutputStream body) {
        byte[] data;
        synchronized (body) { data = body.toByteArray(); }
        if (data.length == 0) return "";
        try {
            return new String(data, "UTF-8");
        } catch (Exception e) {
            return "<" + data.length + " bytes>";
        }
    }

    private static String[] captureStack() {
        StackTraceElement[] st = Thread.currentThread().getStackTrace();
        int start = Math.min(st.length, 4);  // skip getStackTrace + tracker frames
        java.util.ArrayList<String> out = new java.util.ArrayList<>();
        for (int i = start; i < st.length && out.size() < 24; i++) {
            String c = st[i].getClassName();
            if (c.startsWith("com.squeeze.agent")) continue;
            out.add(st[i].toString());
        }
        return out.toArray(new String[0]);
    }
}
