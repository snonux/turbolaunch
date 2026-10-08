package org.buetow.turbolaunch

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
import java.lang.ref.WeakReference

/**
 * Opt-in service that only performs global actions: split screen for app
 * pairs, lock screen, and the notification shade. It ignores every
 * accessibility event.
 */
class TurboLaunchAccessibilityService : AccessibilityService() {
    override fun onServiceConnected() {
        super.onServiceConnected()
        current = WeakReference(this)
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        current = WeakReference(null)
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    companion object {
        @Volatile
        private var current: WeakReference<TurboLaunchAccessibilityService> = WeakReference(null)

        /** The running service, or null when the user has not enabled it. */
        fun instance(): TurboLaunchAccessibilityService? = current.get()
    }
}
