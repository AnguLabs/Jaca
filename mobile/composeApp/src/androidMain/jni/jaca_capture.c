// Jaca on-device capture: a userspace TCP/IP relay built on zdtun (LGPL-3.0).
//
// Why this exists: the kernel-redirect technique (rewrite tun packets to a local
// listening socket) doesn't work on the Android emulator — the kernel won't deliver
// reinjected packets to the local socket. zdtun implements TCP in userspace and opens
// one real upstream socket per connection, so there's no local listener and it works on
// emulators and devices alike. Each upstream socket is protect()-ed (via JNI back into
// JacaVpnService) so its traffic bypasses the VPN and the device stays online.

#include <jni.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/select.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <android/log.h>

#include "zdtun/zdtun.h"

#define TAG "jaca-native"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

typedef struct {
    JNIEnv *env;            // valid for the lifetime of nativeRun (same thread)
    jobject svc;            // JacaVpnService instance
    jmethodID protect_mid;  // boolean protectFd(int fd)
    jmethodID onconn_mid;   // void onConnection(int proto, String src, int sport, String dst, int dport)
    int tunfd;
} jaca_ctx_t;

static volatile int g_running = 0;

// When set, TLS(443) connections are DNAT'd to the on-phone tunnel bridge (loopback),
// which forwards them to the desktop decryption proxy. Everything else goes direct.
static volatile int g_dnat_on = 0;
static uint32_t g_dnat_ip = 0;     // network order (127.0.0.1)
static volatile int g_dnat_port = 0;

// Write a synthesized packet back to the app through the tun fd.
static int cb_send_client(zdtun_t *tun, zdtun_pkt_t *pkt, const zdtun_conn_t *conn) {
    jaca_ctx_t *ctx = (jaca_ctx_t *) zdtun_userdata(tun);
    ssize_t n = write(ctx->tunfd, pkt->buf, pkt->len);
    return (n == pkt->len) ? 0 : -1;
}

// Protect each upstream socket so its traffic bypasses the VPN (keeps the device online).
static void cb_on_socket_open(zdtun_t *tun, socket_t sock) {
    jaca_ctx_t *ctx = (jaca_ctx_t *) zdtun_userdata(tun);
    JNIEnv *env = ctx->env;
    (*env)->CallBooleanMethod(env, ctx->svc, ctx->protect_mid, (jint) sock);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
}

// New connection: hand the 5-tuple to Kotlin for per-app attribution + desktop broadcast.
static int cb_on_connection_open(zdtun_t *tun, zdtun_conn_t *conn) {
    jaca_ctx_t *ctx = (jaca_ctx_t *) zdtun_userdata(tun);
    const zdtun_5tuple_t *t = zdtun_conn_get_5tuple(conn);
    if (t->ipver != 4) return 0; // IPv4 only for now (matches attribution path)

    // While decryption is on, block QUIC (UDP/443) so apps fall back to TCP TLS, which we can
    // route to the desktop proxy and decrypt. Without this, Chrome and most Google traffic
    // stays on QUIC and never gets decrypted. When decryption is off, let QUIC flow normally.
    if (g_dnat_on && t->ipproto == IPPROTO_UDP && ntohs(t->dst_port) == 443)
        return 1; // drop -> the client retries over TCP

    char src[INET_ADDRSTRLEN], dst[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &t->src_ip.ip4, src, sizeof(src));
    inet_ntop(AF_INET, &t->dst_ip.ip4, dst, sizeof(dst));

    JNIEnv *env = ctx->env;
    jstring jsrc = (*env)->NewStringUTF(env, src);
    jstring jdst = (*env)->NewStringUTF(env, dst);
    (*env)->CallVoidMethod(env, ctx->svc, ctx->onconn_mid,
                           (jint) t->ipproto, jsrc, (jint) ntohs(t->src_port),
                           jdst, (jint) ntohs(t->dst_port));
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    (*env)->DeleteLocalRef(env, jsrc);
    (*env)->DeleteLocalRef(env, jdst);

    // Route TLS to the desktop decryption proxy via the loopback bridge (the bridge falls
    // back to direct if the proxy is unreachable, so connectivity is never lost).
    if (g_dnat_on && t->ipproto == IPPROTO_TCP && ntohs(t->dst_port) == 443) {
        zdtun_ip_t pip;
        pip.ip4 = g_dnat_ip;
        zdtun_conn_dnat(conn, &pip, htons((uint16_t) g_dnat_port), 4);
    }
    return 0; // accept
}

JNIEXPORT void JNICALL
Java_dev_srsouza_jaca_JacaVpnService_nativeRun(JNIEnv *env, jobject thiz, jint tunfd, jint sdk) {
    jclass cls = (*env)->GetObjectClass(env, thiz);
    jaca_ctx_t ctx;
    ctx.env = env;
    ctx.svc = thiz;
    ctx.tunfd = tunfd;
    ctx.protect_mid = (*env)->GetMethodID(env, cls, "protectFd", "(I)Z");
    ctx.onconn_mid = (*env)->GetMethodID(env, cls, "onConnection",
                                         "(ILjava/lang/String;ILjava/lang/String;I)V");

    zdtun_callbacks_t cb;
    memset(&cb, 0, sizeof(cb));
    cb.send_client = cb_send_client;
    cb.on_socket_open = cb_on_socket_open;
    cb.on_connection_open = cb_on_connection_open;

    zdtun_t *zdt = zdtun_init(&cb, &ctx);
    if (!zdt) { LOGE("zdtun_init failed"); return; }
    LOGI("capture loop started (tunfd=%d, sdk=%d)", tunfd, sdk);

    char buf[65536];
    g_running = 1;
    time_t last_purge = time(NULL);

    while (g_running) {
        int max_fd = 0;
        fd_set rdfd, wrfd;
        FD_ZERO(&rdfd);
        FD_ZERO(&wrfd);
        zdtun_fds(zdt, &max_fd, &rdfd, &wrfd);
        FD_SET(tunfd, &rdfd);
        if (tunfd > max_fd) max_fd = tunfd;

        struct timeval tv = {0, 250000}; // 250ms so we re-check g_running
        int r = select(max_fd + 1, &rdfd, &wrfd, NULL, &tv);
        if (r < 0) {
            if (errno == EINTR) continue;
            LOGE("select: %s", strerror(errno));
            break;
        }

        if (FD_ISSET(tunfd, &rdfd)) {
            ssize_t n = read(tunfd, buf, sizeof(buf));
            if (n <= 0) {
                if (n < 0 && errno == EINTR) continue;
                LOGI("tun closed (n=%zd)", n);
                break;
            }
            zdtun_easy_forward(zdt, buf, (int) n); // parse + lookup + forward
        }

        zdtun_handle_fd(zdt, &rdfd, &wrfd);

        time_t now = time(NULL);
        if (now - last_purge >= 5) {
            zdtun_purge_expired(zdt);
            last_purge = now;
        }
    }

    zdtun_finalize(zdt);
    LOGI("capture loop ended");
}

JNIEXPORT void JNICALL
Java_dev_srsouza_jaca_JacaVpnService_nativeStop(JNIEnv *env, jobject thiz) {
    g_running = 0;
}

JNIEXPORT void JNICALL
Java_dev_srsouza_jaca_JacaVpnService_nativeSetDnat(JNIEnv *env, jobject thiz, jint bridgePort) {
    g_dnat_ip = inet_addr("127.0.0.1");
    g_dnat_port = bridgePort;
    g_dnat_on = 1;
}

JNIEXPORT void JNICALL
Java_dev_srsouza_jaca_JacaVpnService_nativeClearDnat(JNIEnv *env, jobject thiz) {
    g_dnat_on = 0;
}
