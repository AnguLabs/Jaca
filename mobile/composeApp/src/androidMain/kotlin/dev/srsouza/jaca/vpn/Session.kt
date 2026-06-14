package dev.srsouza.jaca.vpn

import java.util.concurrent.ConcurrentHashMap

/// One intercepted connection. Keyed by [localPort] (the app's source port on the tun),
/// which is how the proxy recovers the original destination after the header rewrite
/// redirects the packet to our local server. Ported from NetBare (MIT).
class Session(
    @JvmField val protocol: Protocol,
    @JvmField val localPort: Short,
    @JvmField val remotePort: Short,
    @JvmField val remoteIp: Int,
) {
    @Volatile @JvmField var attributed: Boolean = false
}

/// Source-port -> Session map. The forwarder records the original destination here
/// before redirecting the packet, so the proxy (which only sees the source port on the
/// accepted socket) can look the destination back up.
class SessionProvider {
    private val sessions = ConcurrentHashMap<Short, Session>()

    fun query(localPort: Short): Session? = sessions[localPort]

    fun ensureQuery(protocol: Protocol, localPort: Short, remotePort: Short, remoteIp: Int): Session {
        var session = sessions[localPort]
        if (session != null &&
            (session.protocol != protocol || session.remotePort != remotePort || session.remoteIp != remoteIp)
        ) {
            session = null
        }
        if (session == null) {
            session = Session(protocol, localPort, remotePort, remoteIp)
            sessions[localPort] = session
        }
        return session
    }

    fun remove(localPort: Short) { sessions.remove(localPort) }
}
