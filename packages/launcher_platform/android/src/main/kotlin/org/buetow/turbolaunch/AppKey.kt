package org.buetow.turbolaunch

/**
 * Identifies one launchable activity in one profile. The Dart side and the
 * home slots store it as the string `package/activity#userSerial`, which stays
 * stable across reboots (user serials do, user handles do not).
 */
data class AppKey(val packageName: String, val activity: String, val userSerial: Long) {
    override fun toString(): String = "$packageName/$activity#$userSerial"

    companion object {
        fun parse(key: String): AppKey? {
            val hash = key.lastIndexOf('#')
            val slash = key.indexOf('/')
            if (hash < 0 || slash <= 0 || slash > hash) return null
            val packageName = key.substring(0, slash)
            val activity = key.substring(slash + 1, hash)
            val serial = key.substring(hash + 1).toLongOrNull() ?: return null
            if (activity.isEmpty()) return null
            return AppKey(packageName, activity, serial)
        }
    }
}
