package org.buetow.turbolaunch

import android.accessibilityservice.AccessibilityService
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log

/**
 * A "Screenshot" tile for quick settings, so a screenshot of any app is a
 * pull-down and a tap away. The tile closes the shade first, then asks the
 * accessibility service for the screenshot once the shade is gone. With the
 * service off, the tile opens the accessibility settings instead.
 */
class ScreenshotTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        val tile = qsTile ?: return
        val on = TurboLaunchAccessibilityService.instance() != null
        // Never unavailable: a tap with the service off has to reach onClick.
        tile.state = Tile.STATE_INACTIVE
        if (Build.VERSION.SDK_INT >= 29) {
            tile.subtitle = if (on) null else getString(R.string.turbolaunch_tile_needs_service)
        }
        tile.updateTile()
    }

    override fun onClick() {
        super.onClick()
        val service = TurboLaunchAccessibilityService.instance()
        if (service == null || Build.VERSION.SDK_INT < 28) {
            openAccessibilitySettings()
            return
        }
        collapseShade(service)
        Handler(Looper.getMainLooper()).postDelayed({
            val taken = service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_TAKE_SCREENSHOT)
            Log.i(TAG, "screenshot tile: $taken")
        }, SHADE_CLOSE_MILLIS)
    }

    /** Closes the shade so it is not in the shot; any failure is silent. */
    @Suppress("WrongConstant")
    private fun collapseShade(service: AccessibilityService) {
        if (Build.VERSION.SDK_INT >= 31 &&
            service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_DISMISS_NOTIFICATION_SHADE)
        ) {
            return
        }
        try {
            val statusBar = getSystemService("statusbar") ?: return
            statusBar.javaClass.getMethod("collapsePanels").invoke(statusBar)
        } catch (e: Exception) {
            Log.i(TAG, "shade could not be closed: $e")
        }
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    private fun openAccessibilitySettings() {
        val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    companion object {
        /** Long enough for the shade's closing animation; a first guess like PAIR_STEP_MILLIS. */
        const val SHADE_CLOSE_MILLIS = 700L
        private const val TAG = "TurboLaunch"
    }
}
