package org.buetow.turbolaunch

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AppKeyTest {
    @Test
    fun roundTrips() {
        val key = AppKey("org.example.maps", "org.example.maps.MainActivity", 10)
        assertEquals("org.example.maps/org.example.maps.MainActivity#10", key.toString())
        assertEquals(key, AppKey.parse(key.toString()))
    }

    @Test
    fun keepsHashesInsideTheActivityName() {
        assertEquals(AppKey("p", "a#b", 0), AppKey.parse("p/a#b#0"))
    }

    @Test
    fun rejectsMalformedKeys() {
        assertNull(AppKey.parse(""))
        assertNull(AppKey.parse("p/a"))
        assertNull(AppKey.parse("/a#0"))
        assertNull(AppKey.parse("p/#0"))
        assertNull(AppKey.parse("p/a#x"))
        assertNull(AppKey.parse("pa#0"))
    }
}
