package org.buetow.turbolaunch

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.nio.file.Files

class IconDiskCacheTest {
    private val maps = AppKey("org.example.maps", "org.example.maps.Main", 0)

    @Test
    fun readsWhatWasWritten() {
        val cache = IconDiskCache(Files.createTempDirectory("icons").toFile())
        assertNull(cache.read(maps, 144, 1))
        cache.write(maps, 144, 1, byteArrayOf(1, 2, 3))
        assertArrayEquals(byteArrayOf(1, 2, 3), cache.read(maps, 144, 1))
    }

    @Test
    fun anUpdateReplacesTheOldIcon() {
        val dir = Files.createTempDirectory("icons").toFile()
        val cache = IconDiskCache(dir)
        cache.write(maps, 144, 1, byteArrayOf(1))
        cache.write(AppKey("org.example.music", "M", 0), 144, 1, byteArrayOf(9))
        cache.write(maps, 144, 2, byteArrayOf(2))
        assertNull(cache.read(maps, 144, 1))
        assertArrayEquals(byteArrayOf(2), cache.read(maps, 144, 2))
        assertEquals(2, dir.listFiles()!!.size)
    }

    @Test
    fun namesAreSafeAndDistinct() {
        val name = IconDiskCache.fileName(maps, 144, 7)
        assertEquals(false, name.contains('/'))
        assertEquals(false, name.contains('#'))
        assertNotEquals(
            IconDiskCache.fileName(AppKey("a", "b_c", 0), 1, 1),
            IconDiskCache.fileName(AppKey("a", "b/c", 0), 1, 1),
        )
    }
}
