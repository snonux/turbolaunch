package org.buetow.turbolaunch

import java.io.File

/**
 * Rendered app icons as PNG files, so a cold start reads them from disk
 * instead of drawing every icon again. A file's name carries a time that
 * changes when the app is updated (its APK's file time), so an updated app
 * gets a fresh icon; writing a new one removes the app's older files.
 */
class IconDiskCache(private val dir: File) {
    fun read(key: AppKey, size: Int, updated: Long): ByteArray? {
        val file = File(dir, fileName(key, size, updated))
        return if (file.isFile) file.readBytes() else null
    }

    fun write(key: AppKey, size: Int, updated: Long, png: ByteArray) {
        dir.mkdirs()
        val name = fileName(key, size, updated)
        val prefix = prefix(key)
        dir.listFiles()?.filter { it.name.startsWith(prefix) && it.name != name }?.forEach { it.delete() }
        // Write then rename, so a reader never sees half a file.
        val tmp = File(dir, "$name.tmp")
        tmp.writeBytes(png)
        tmp.renameTo(File(dir, name))
    }

    fun clear() {
        dir.listFiles()?.forEach { it.delete() }
    }

    /**
     * Empties the cache when [stamp] (the system build) differs from the one it
     * was filled under: a system update can change system apps' icons without
     * changing their APK's file time.
     */
    fun resetIfChanged(stamp: String) {
        val file = File(dir, STAMP)
        if (file.isFile && file.readText() == stamp) return
        clear()
        dir.mkdirs()
        file.writeText(stamp)
    }

    companion object {
        private const val STAMP = "build.stamp"

        /** Every character outside [A-Za-z0-9._] becomes `_` plus its code, so names stay unique. */
        private fun safe(s: String): String =
            buildString {
                for (c in s) if (c.isLetterOrDigit() || c == '.') append(c) else append('_').append(c.code).append('_')
            }

        fun prefix(key: AppKey): String = safe(key.toString()) + "-"

        fun fileName(key: AppKey, size: Int, updated: Long): String = "${prefix(key)}$size-$updated.png"
    }
}
