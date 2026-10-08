package org.buetow.turbolaunch

import android.accessibilityservice.AccessibilityService
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.LauncherActivityInfo
import android.content.pm.LauncherApps
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.os.UserHandle
import android.os.UserManager
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The Android side of TurboLaunch: lists launchable activities in every
 * profile, renders their icons, launches them, and reports package changes and
 * Home presses to Dart as events.
 */
class LauncherPlatformPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    PluginRegistry.NewIntentListener {
    private lateinit var context: Context
    private lateinit var launcherApps: LauncherApps
    private lateinit var userManager: UserManager
    private var channel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var events: EventChannel.EventSink? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private val main = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newFixedThreadPool(2)

    private val packageCallback =
        object : LauncherApps.Callback() {
            override fun onPackageRemoved(packageName: String, user: UserHandle) = emit("packages")

            override fun onPackageAdded(packageName: String, user: UserHandle) = emit("packages")

            override fun onPackageChanged(packageName: String, user: UserHandle) = emit("packages")

            override fun onPackagesAvailable(packageNames: Array<out String>, user: UserHandle, replacing: Boolean) =
                emit("packages")

            override fun onPackagesUnavailable(
                packageNames: Array<out String>,
                user: UserHandle,
                replacing: Boolean,
            ) = emit("packages")
        }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        launcherApps = context.getSystemService(LauncherApps::class.java)
        userManager = context.getSystemService(UserManager::class.java)
        channel = MethodChannel(binding.binaryMessenger, "launcher_platform").also { it.setMethodCallHandler(this) }
        eventChannel = EventChannel(binding.binaryMessenger, "launcher_platform/events").also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        onCancel(null)
        worker.shutdown()
    }

    // --- Activity: Home presses arrive as a new intent on the singleTask activity.

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addOnNewIntentListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onNewIntent(intent: Intent): Boolean {
        if (intent.action == Intent.ACTION_MAIN && intent.hasCategory(Intent.CATEGORY_HOME)) emit("home")
        return false
    }

    // --- Events

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        events = sink
        launcherApps.registerCallback(packageCallback, main)
    }

    override fun onCancel(arguments: Any?) {
        if (events != null) launcherApps.unregisterCallback(packageCallback)
        events = null
    }

    private fun emit(event: String) {
        main.post { events?.success(event) }
    }

    // --- Methods

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "listApps" -> background(result) { listApps() }
            "icon" -> background(result) { icon(call.key(), call.argument<Int>("size") ?: 144) }
            "launch" -> result.success(launch(call.key()))
            "appInfo" -> result.success(appInfo(call.key()))
            "startupMillis" ->
                result.success(SystemClock.elapsedRealtime() - Process.getStartElapsedRealtime())
            "splitServiceEnabled" -> result.success(TurboLaunchAccessibilityService.instance() != null)
            "openAccessibilitySettings" -> result.success(startSettings(Settings.ACTION_ACCESSIBILITY_SETTINGS))
            "openHomeSettings" -> result.success(startSettings(Settings.ACTION_HOME_SETTINGS))
            "launchPair" -> launchPair(call.key("first"), call.key("second"), result)
            else -> result.notImplemented()
        }
    }

    private fun MethodCall.key(name: String = "key"): AppKey? = argument<String>(name)?.let { AppKey.parse(it) }

    private fun <T> background(result: MethodChannel.Result, work: () -> T) {
        worker.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("platform", e.message, null) }
            }
        }
    }

    private fun listApps(): List<Map<String, Any>> {
        val own = Process.myUserHandle()
        return launcherApps.profiles.flatMap { user ->
            val serial = userManager.getSerialNumberForUser(user)
            launcherApps.getActivityList(null, user)
                .filter { it.applicationInfo.packageName != context.packageName }
                .map { info ->
                    mapOf(
                        "key" to AppKey(info.applicationInfo.packageName, info.name, serial).toString(),
                        "label" to info.label.toString(),
                        "otherProfile" to (user != own),
                    )
                }
        }
    }

    private fun resolve(key: AppKey?): LauncherActivityInfo? {
        if (key == null) return null
        val user = userManager.getUserForSerialNumber(key.userSerial) ?: return null
        return launcherApps.getActivityList(key.packageName, user).firstOrNull { it.name == key.activity }
    }

    private fun icon(key: AppKey?, size: Int): ByteArray? {
        val info = resolve(key) ?: return null
        val drawable = info.getBadgedIcon(0)
        val out = ByteArrayOutputStream()
        drawableToBitmap(drawable, size).compress(Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
    }

    private fun drawableToBitmap(drawable: Drawable, size: Int): Bitmap {
        if (drawable is BitmapDrawable && drawable.bitmap.width == size) return drawable.bitmap
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(Canvas(bitmap))
        return bitmap
    }

    private fun launch(key: AppKey?, flags: Int = 0): Boolean {
        val info = resolve(key) ?: return false
        return try {
            if (flags == 0) {
                launcherApps.startMainActivity(info.componentName, info.user, null, null)
            } else {
                // startMainActivity takes no flags, so an adjacent launch builds the
                // intent itself. Only apps in our own profile can be started this way.
                val intent =
                    Intent(Intent.ACTION_MAIN)
                        .addCategory(Intent.CATEGORY_LAUNCHER)
                        .setComponent(ComponentName(info.applicationInfo.packageName, info.name))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or flags)
                (activity ?: context).startActivity(intent)
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun appInfo(key: AppKey?): Boolean {
        val info = resolve(key) ?: return false
        return try {
            launcherApps.startAppDetailsActivity(info.componentName, info.user, null, null)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun startSettings(action: String): Boolean =
        try {
            (activity ?: context).startActivity(Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (e: Exception) {
            false
        }

    /**
     * Phase 1 spike: open two apps side by side. Third-party launchers have no
     * app-pair API, so this starts the first app, asks the opt-in accessibility
     * service to toggle split screen, then starts the second app adjacent to it.
     * Returns "split" when every step ran, "no_service" when the service is off
     * (only the first app is opened), or "failed".
     */
    private fun launchPair(first: AppKey?, second: AppKey?, result: MethodChannel.Result) {
        if (!launch(first)) return result.success("failed")
        val service = TurboLaunchAccessibilityService.instance()
        if (service == null) return result.success("no_service")
        main.postDelayed({
            if (!service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_TOGGLE_SPLIT_SCREEN)) {
                result.success("failed")
                return@postDelayed
            }
            main.postDelayed({
                val adjacent = Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT or Intent.FLAG_ACTIVITY_MULTIPLE_TASK
                result.success(if (launch(second, adjacent)) "split" else "failed")
            }, PAIR_STEP_MILLIS)
        }, PAIR_STEP_MILLIS)
    }

    private companion object {
        // Time for the window manager to settle between the pair's steps; tuned on device.
        const val PAIR_STEP_MILLIS = 600L
    }
}
