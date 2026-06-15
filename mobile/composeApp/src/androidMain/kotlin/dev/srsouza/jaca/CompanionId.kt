package dev.srsouza.jaca

import android.content.Context
import java.util.UUID

/// A stable per-install identifier so the desktop recognizes THIS device across IP changes
/// (Wi-Fi reconnects hand out new addresses) and shows it as a single entry — identity by
/// device, not by address. Advertised in the mDNS TXT record; persisted on first use.
object CompanionId {
    private const val PREFS = "jaca_companion"
    private const val KEY = "device_id"

    @Volatile
    private var cached: String? = null

    fun get(context: Context): String {
        cached?.let { return it }
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val id = prefs.getString(KEY, null)
            ?: UUID.randomUUID().toString().also { prefs.edit().putString(KEY, it).apply() }
        cached = id
        return id
    }
}
