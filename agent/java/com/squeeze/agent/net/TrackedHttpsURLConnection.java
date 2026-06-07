package com.squeeze.agent.net;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.security.Permission;
import java.security.Principal;
import java.security.cert.Certificate;
import java.util.List;
import java.util.Map;

import javax.net.ssl.HostnameVerifier;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLPeerUnverifiedException;
import javax.net.ssl.SSLSocketFactory;

/** Delegating HttpsURLConnection that records the request/response via SqueezeTracker. */
public final class TrackedHttpsURLConnection extends HttpsURLConnection {
    private final HttpsURLConnection d;
    private final SqueezeTracker tracker;
    private boolean requestCaptured = false;

    public TrackedHttpsURLConnection(HttpsURLConnection delegate, SqueezeTracker tracker) {
        super(delegate.getURL());
        this.d = delegate;
        this.tracker = tracker;
    }

    private void captureRequest() {
        if (requestCaptured) return;
        requestCaptured = true;
        try {
            tracker.setMethod(d.getRequestMethod());
            tracker.setRequestHeaders(d.getRequestProperties());
        } catch (Throwable ignored) {}
    }

    private void captureResponse() {
        try { tracker.onResponse(d.getResponseCode(), d.getHeaderFields()); }
        catch (Throwable ignored) {}
    }

    // --- capture points ---
    @Override public void connect() throws IOException { captureRequest(); d.connect(); }
    @Override public OutputStream getOutputStream() throws IOException {
        captureRequest();
        return new TeeStreams.RequestStream(d.getOutputStream(), tracker);
    }
    @Override public int getResponseCode() throws IOException {
        captureRequest();
        int code = d.getResponseCode();
        tracker.onResponse(code, d.getHeaderFields());
        return code;
    }
    @Override public InputStream getInputStream() throws IOException {
        captureRequest();
        try {
            captureResponse();
            return new TeeStreams.ResponseStream(d.getInputStream(), tracker);
        } catch (IOException e) {
            tracker.setError(String.valueOf(e)); tracker.report(); throw e;
        }
    }
    @Override public InputStream getErrorStream() {
        InputStream es = d.getErrorStream();
        return es == null ? null : new TeeStreams.ResponseStream(es, tracker);
    }
    @Override public void disconnect() { tracker.report(); d.disconnect(); }

    // --- HttpURLConnection / URLConnection delegation ---
    @Override public boolean usingProxy() { return d.usingProxy(); }
    @Override public String getResponseMessage() throws IOException { return d.getResponseMessage(); }
    @Override public void setRequestMethod(String m) throws java.net.ProtocolException { d.setRequestMethod(m); }
    @Override public String getRequestMethod() { return d.getRequestMethod(); }
    @Override public void setInstanceFollowRedirects(boolean f) { d.setInstanceFollowRedirects(f); }
    @Override public boolean getInstanceFollowRedirects() { return d.getInstanceFollowRedirects(); }
    @Override public void setFixedLengthStreamingMode(int n) { d.setFixedLengthStreamingMode(n); }
    @Override public void setFixedLengthStreamingMode(long n) { d.setFixedLengthStreamingMode(n); }
    @Override public void setChunkedStreamingMode(int n) { d.setChunkedStreamingMode(n); }
    @Override public Permission getPermission() throws IOException { return d.getPermission(); }
    @Override public String getHeaderFieldKey(int n) { return d.getHeaderFieldKey(n); }
    @Override public String getHeaderField(int n) { return d.getHeaderField(n); }
    @Override public String getHeaderField(String name) { return d.getHeaderField(name); }
    @Override public Map<String, List<String>> getHeaderFields() { return d.getHeaderFields(); }
    @Override public int getHeaderFieldInt(String n, int def) { return d.getHeaderFieldInt(n, def); }
    @Override public long getHeaderFieldDate(String n, long def) { return d.getHeaderFieldDate(n, def); }
    @Override public void setConnectTimeout(int t) { d.setConnectTimeout(t); }
    @Override public int getConnectTimeout() { return d.getConnectTimeout(); }
    @Override public void setReadTimeout(int t) { d.setReadTimeout(t); }
    @Override public int getReadTimeout() { return d.getReadTimeout(); }
    @Override public java.net.URL getURL() { return d.getURL(); }
    @Override public int getContentLength() { return d.getContentLength(); }
    @Override public long getContentLengthLong() { return d.getContentLengthLong(); }
    @Override public String getContentType() { return d.getContentType(); }
    @Override public String getContentEncoding() { return d.getContentEncoding(); }
    @Override public long getExpiration() { return d.getExpiration(); }
    @Override public long getDate() { return d.getDate(); }
    @Override public long getLastModified() { return d.getLastModified(); }
    @Override public Object getContent() throws IOException { return d.getContent(); }
    @Override public Object getContent(Class[] c) throws IOException { return d.getContent(c); }
    @Override public void setDoInput(boolean v) { d.setDoInput(v); }
    @Override public boolean getDoInput() { return d.getDoInput(); }
    @Override public void setDoOutput(boolean v) { d.setDoOutput(v); }
    @Override public boolean getDoOutput() { return d.getDoOutput(); }
    @Override public void setAllowUserInteraction(boolean v) { d.setAllowUserInteraction(v); }
    @Override public boolean getAllowUserInteraction() { return d.getAllowUserInteraction(); }
    @Override public void setUseCaches(boolean v) { d.setUseCaches(v); }
    @Override public boolean getUseCaches() { return d.getUseCaches(); }
    @Override public void setIfModifiedSince(long v) { d.setIfModifiedSince(v); }
    @Override public long getIfModifiedSince() { return d.getIfModifiedSince(); }
    @Override public void setDefaultUseCaches(boolean v) { d.setDefaultUseCaches(v); }
    @Override public boolean getDefaultUseCaches() { return d.getDefaultUseCaches(); }
    @Override public void setRequestProperty(String k, String v) { d.setRequestProperty(k, v); }
    @Override public void addRequestProperty(String k, String v) { d.addRequestProperty(k, v); }
    @Override public String getRequestProperty(String k) { return d.getRequestProperty(k); }
    @Override public Map<String, List<String>> getRequestProperties() { return d.getRequestProperties(); }

    // --- HttpsURLConnection specifics ---
    @Override public String getCipherSuite() { return d.getCipherSuite(); }
    @Override public Certificate[] getLocalCertificates() { return d.getLocalCertificates(); }
    @Override public Certificate[] getServerCertificates() throws SSLPeerUnverifiedException { return d.getServerCertificates(); }
    @Override public Principal getPeerPrincipal() throws SSLPeerUnverifiedException { return d.getPeerPrincipal(); }
    @Override public Principal getLocalPrincipal() { return d.getLocalPrincipal(); }
    @Override public void setHostnameVerifier(HostnameVerifier v) { d.setHostnameVerifier(v); }
    @Override public HostnameVerifier getHostnameVerifier() { return d.getHostnameVerifier(); }
    @Override public void setSSLSocketFactory(SSLSocketFactory f) { d.setSSLSocketFactory(f); }
    @Override public SSLSocketFactory getSSLSocketFactory() { return d.getSSLSocketFactory(); }
}
