package dev.srsouza.jaca

import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.os.Process
import android.system.OsConstants
import java.net.InetAddress
import java.net.InetSocketAddress

/// Resolves which app owns a TCP flow via getConnectionOwnerUid (API 29+) — the
/// modern, non-root way to attribute traffic (replaces NetBare's /proc/net parsing,
/// which Android 10+ blocks). Caches uid→label.
class FlowAttributor(context: Context) {
    private val cm = context.getSystemService(ConnectivityManager::class.java)
    private val pm = context.packageManager
    private val labelCache = HashMap<Int, Pair<String, String>>() // uid -> (label, package)

    fun attribute(flow: Flow): CapturedFlow? {
        val uid = ownerUid(flow)
        if (uid < 0 || uid == Process.INVALID_UID) return null
        val (label, pkg) = labelCache.getOrPut(uid) { resolveLabel(uid) }
        return CapturedFlow(
            app = label, packageName = pkg, host = flow.dstIp, port = flow.dstPort,
            protocol = if (flow.protocol == 6) "TCP" else "UDP"
        )
    }

    private fun ownerUid(flow: Flow): Int = try {
        cm.getConnectionOwnerUid(
            if (flow.protocol == 6) OsConstants.IPPROTO_TCP else OsConstants.IPPROTO_UDP,
            InetSocketAddress(InetAddress.getByName(flow.srcIp), flow.srcPort),
            InetSocketAddress(InetAddress.getByName(flow.dstIp), flow.dstPort)
        )
    } catch (_: Exception) {
        Process.INVALID_UID
    }

    private fun resolveLabel(uid: Int): Pair<String, String> {
        val pkgs = pm.getPackagesForUid(uid)
        val pkg = pkgs?.firstOrNull() ?: return "uid $uid" to "uid:$uid"
        val label = try {
            pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
        } catch (_: PackageManager.NameNotFoundException) {
            pkg
        }
        return label to pkg
    }
}
