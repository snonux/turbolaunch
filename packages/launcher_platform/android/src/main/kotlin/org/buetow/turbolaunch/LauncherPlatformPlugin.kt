package org.buetow.turbolaunch

import android.accessibilityservice.AccessibilityService
import android.app.Activity
import android.app.WallpaperManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.LauncherActivityInfo
import android.content.pm.LauncherApps
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.os.UserHandle
import android.os.UserManager
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
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
    PluginRegistry.NewIntentListener,
    PluginRegistry.ActivityResultListener {
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

    // Opened on the first icon request, off the main thread.
    private val iconCache by lazy {
        IconDiskCache(File(context.cacheDir, "icons")).also { it.resetIfChanged(Build.FINGERPRINT) }
    }

    // The activities the last listApps found, by key, so an icon request
    // needs no binder call to find its app again.
    private val listed = ConcurrentHashMap<String, LauncherActivityInfo>()

    // The wallpaper pick in flight: which screens to set, and who to answer.
    private var wallpaperFlags = 0
    private var wallpaperResult: MethodChannel.Result? = null

    // The settings file dialog in flight, and the text to write for an export.
    private var fileResult: MethodChannel.Result? = null
    private var fileContent: String? = null

    // A work profile paused, resumed, added or removed changes the app list.
    private val profileReceiver =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) = packagesChanged()
        }

    private val packageCallback =
        object : LauncherApps.Callback() {
            override fun onPackageRemoved(packageName: String, user: UserHandle) = packagesChanged()

            override fun onPackageAdded(packageName: String, user: UserHandle) = packagesChanged()

            override fun onPackageChanged(packageName: String, user: UserHandle) = packagesChanged()

            override fun onPackagesAvailable(packageNames: Array<out String>, user: UserHandle, replacing: Boolean) =
                packagesChanged()

            override fun onPackagesUnavailable(
                packageNames: Array<out String>,
                user: UserHandle,
                replacing: Boolean,
            ) = packagesChanged()
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
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding?.removeActivityResultListener(this)
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
        val filter =
            IntentFilter().apply {
                addAction(Intent.ACTION_MANAGED_PROFILE_AVAILABLE)
                addAction(Intent.ACTION_MANAGED_PROFILE_UNAVAILABLE)
                addAction(Intent.ACTION_MANAGED_PROFILE_ADDED)
                addAction(Intent.ACTION_MANAGED_PROFILE_REMOVED)
            }
        // Protected system broadcasts, so not exporting the receiver is enough.
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(profileReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(profileReceiver, filter)
        }
    }

    override fun onCancel(arguments: Any?) {
        if (events != null) {
            launcherApps.unregisterCallback(packageCallback)
            context.unregisterReceiver(profileReceiver)
        }
        events = null
    }

    // The remembered activities may be stale now; Dart lists the apps again.
    private fun packagesChanged() {
        listed.clear()
        emit("packages")
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
            "benchMode" -> result.success(benchMode())
            "splitServiceEnabled" -> result.success(TurboLaunchAccessibilityService.instance() != null)
            "lockScreen" -> result.success(lockScreen())
            "expandNotifications" -> result.success(expandNotifications())
            "saveTextFile" ->
                saveTextFile(call.argument<String>("name") ?: "turbolaunch.json", call.argument<String>("content"), result)
            "openTextFile" -> openTextFile(result)
            "openAccessibilitySettings" -> result.success(startSettings(Settings.ACTION_ACCESSIBILITY_SETTINGS))
            "openHomeSettings" -> result.success(startSettings(Settings.ACTION_HOME_SETTINGS))
            "launchPair" -> launchPair(call.key("first"), call.key("second"), result)
            "battery" ->
                result.success(
                    context.getSystemService(BatteryManager::class.java)
                        .getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY),
                )
            "uninstall" -> result.success(uninstall(call.key()))
            "shortcuts" -> background(result) { shortcuts() }
            "startShortcut" ->
                result.success(
                    startShortcut(
                        call.argument<String>("package"),
                        call.argument<String>("id"),
                        call.argument<Number>("userSerial")?.toLong(),
                    ),
                )
            "pickWallpaper" -> pickWallpaper(call.argument<String>("target") ?: "home", result)
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
        val found = HashMap<String, LauncherActivityInfo>()
        val apps = launcherApps.profiles.flatMap { user ->
            val serial = userManager.getSerialNumberForUser(user)
            // A paused work profile still lists its apps; starting one asks to resume the profile.
            val paused = user != own && userManager.isQuietModeEnabled(user)
            launcherApps.getActivityList(null, user)
                .filter { it.applicationInfo.packageName != context.packageName }
                .map { info ->
                    val key = AppKey(info.applicationInfo.packageName, info.name, serial).toString()
                    found[key] = info
                    mapOf(
                        "key" to key,
                        "label" to info.label.toString(),
                        "otherProfile" to (user != own),
                        "paused" to paused,
                    )
                }
        }
        listed.keys.retainAll(found.keys)
        listed.putAll(found)
        return apps
    }

    private fun resolve(key: AppKey?): LauncherActivityInfo? {
        if (key == null) return null
        listed[key.toString()]?.let { return it }
        val user = userManager.getUserForSerialNumber(key.userSerial) ?: return null
        return launcherApps.getActivityList(key.packageName, user).firstOrNull { it.name == key.activity }
    }

    private fun icon(key: AppKey?, size: Int): ByteArray? {
        val info = resolve(key) ?: return null
        val updated = updateStamp(info)
        iconCache.read(key!!, size, updated)?.let { return it }
        val drawable = info.getBadgedIcon(0)
        val out = ByteArrayOutputStream()
        drawableToBitmap(drawable, size).compress(Bitmap.CompressFormat.PNG, 100, out)
        val png = out.toByteArray()
        try {
            iconCache.write(key, size, updated, png)
        } catch (e: IOException) {
            // A full disk only costs the next start some time.
        }
        return png
    }

    /**
     * Changes when the app is updated: an update installs a new APK file. Read
     * from the file system, so no binder call; a system update, which can keep
     * the file time, empties the whole icon cache instead.
     */
    private fun updateStamp(info: LauncherActivityInfo): Long {
        val time = File(info.applicationInfo.sourceDir ?: "").lastModified()
        if (time > 0) return time
        return try {
            context.packageManager.getPackageInfo(info.applicationInfo.packageName, 0).lastUpdateTime
        } catch (e: Exception) {
            0L
        }
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

    /** Locks the phone through the opt-in accessibility service; false when it is off. */
    private fun lockScreen(): Boolean {
        val service = TurboLaunchAccessibilityService.instance() ?: return false
        if (Build.VERSION.SDK_INT < 28) return false
        return service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN).also {
            Log.i(TAG, "lock screen: $it")
        }
    }

    /**
     * Pulls down the notification shade: through the accessibility service when
     * it is on, otherwise through the hidden StatusBarManager call that home apps
     * have long used. That one may disappear in a future Android, so any failure
     * just returns false.
     */
    @Suppress("WrongConstant")
    private fun expandNotifications(): Boolean {
        TurboLaunchAccessibilityService.instance()?.let {
            if (it.performGlobalAction(AccessibilityService.GLOBAL_ACTION_NOTIFICATIONS)) {
                Log.i(TAG, "notifications opened through the accessibility service")
                return true
            }
        }
        return try {
            val statusBar = context.getSystemService("statusbar") ?: return false
            statusBar.javaClass.getMethod("expandNotificationsPanel").invoke(statusBar)
            Log.i(TAG, "notifications opened through the status bar")
            true
        } catch (e: Exception) {
            Log.i(TAG, "notifications could not be opened: $e")
            false
        }
    }

    /**
     * Settings export: the system "Create document" dialog, so no storage
     * permission is needed. Answers the chosen file's name, or null when cancelled.
     */
    private fun saveTextFile(name: String, content: String?, result: MethodChannel.Result) {
        if (content == null) return result.error("bad_args", "Nothing to save.", null)
        val intent =
            Intent(Intent.ACTION_CREATE_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType("application/json")
                .putExtra(Intent.EXTRA_TITLE, name)
        startFileDialog(intent, SAVE_FILE_REQUEST, content, result)
    }

    /** Settings import: the system "Open document" dialog. Answers the file's text, or null. */
    private fun openTextFile(result: MethodChannel.Result) {
        // File managers label .json inconsistently, so accept anything; Dart validates it.
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
        startFileDialog(intent, OPEN_FILE_REQUEST, null, result)
    }

    private fun startFileDialog(intent: Intent, request: Int, content: String?, result: MethodChannel.Result) {
        val host = activity ?: return result.error("no_activity", "TurboLaunch is not in front.", null)
        if (fileResult != null) return result.error("busy", "Another file dialog is already open.", null)
        fileResult = result
        fileContent = content
        try {
            host.startActivityForResult(intent, request)
        } catch (e: Exception) {
            fileResult = null
            fileContent = null
            result.error("no_picker", "No file manager app is available.", null)
        }
    }

    private fun finishFileDialog(requestCode: Int, resultCode: Int, data: Intent?) {
        val result = fileResult
        val content = fileContent
        fileResult = null
        fileContent = null
        val uri = data?.data
        if (result == null) {
            // The process died while the dialog was open: drop the empty file an export left.
            if (requestCode == SAVE_FILE_REQUEST && resultCode == Activity.RESULT_OK && uri != null) {
                try {
                    DocumentsContract.deleteDocument(context.contentResolver, uri)
                } catch (e: Exception) {
                }
            }
            return
        }
        if (resultCode != Activity.RESULT_OK || uri == null) return result.success(null)
        background(result) {
            val resolver = context.contentResolver
            if (requestCode == SAVE_FILE_REQUEST) {
                // "wt" truncates; a few providers reject it, and a new document is empty anyway.
                val out =
                    try {
                        resolver.openOutputStream(uri, "wt")
                    } catch (e: Exception) {
                        resolver.openOutputStream(uri, "w")
                    } ?: throw IOException("Cannot write the selected file.")
                out.use { it.write((content ?: "").toByteArray(Charsets.UTF_8)) }
                displayName(uri)
            } else {
                val input = resolver.openInputStream(uri) ?: throw IOException("Cannot open the selected file.")
                input.use { it.readBytes().toString(Charsets.UTF_8) }
            }
        }
    }

    private fun displayName(uri: Uri): String =
        try {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            }
        } catch (e: Exception) {
            null
        } ?: uri.lastPathSegment ?: "the chosen file"

    private fun uninstall(key: AppKey?): Boolean {
        if (key == null) return false
        return try {
            val intent =
                Intent(Intent.ACTION_DELETE, Uri.fromParts("package", key.packageName, null))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            (activity ?: context).startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Every app's long-press shortcuts, in every profile. Android only shows
     * them to the default home app, so this is empty until TurboLaunch is it.
     */
    private fun shortcuts(): List<Map<String, Any>> {
        if (!launcherApps.hasShortcutHostPermission()) return emptyList()
        val query =
            LauncherApps.ShortcutQuery().setQueryFlags(
                LauncherApps.ShortcutQuery.FLAG_MATCH_DYNAMIC or
                    LauncherApps.ShortcutQuery.FLAG_MATCH_MANIFEST or
                    LauncherApps.ShortcutQuery.FLAG_MATCH_PINNED,
            )
        return launcherApps.profiles.flatMap { user ->
            val serial = userManager.getSerialNumberForUser(user)
            val list =
                try {
                    launcherApps.getShortcuts(query, user) ?: emptyList()
                } catch (e: Exception) {
                    emptyList()
                }
            list.filter { it.isEnabled }.map { info ->
                mapOf(
                    "package" to info.`package`,
                    "id" to info.id,
                    "userSerial" to serial,
                    "label" to (info.shortLabel ?: info.longLabel ?: info.id).toString(),
                )
            }
        }
    }

    private fun startShortcut(packageName: String?, id: String?, serial: Long?): Boolean {
        if (packageName == null || id == null || serial == null) return false
        val user = userManager.getUserForSerialNumber(serial) ?: return false
        return try {
            launcherApps.startShortcut(packageName, id, null, null, user)
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Lets the user pick an image with the system photo picker (no storage
     * permission) and sets it as the home, lock or both wallpapers. Answers
     * true when set, false on failure, null when the user cancelled.
     */
    private fun pickWallpaper(target: String, result: MethodChannel.Result) {
        val host = activity ?: return result.success(false)
        if (wallpaperResult != null) return result.success(false)
        wallpaperFlags =
            when (target) {
                "lock" -> WallpaperManager.FLAG_LOCK
                "both" -> WallpaperManager.FLAG_SYSTEM or WallpaperManager.FLAG_LOCK
                else -> WallpaperManager.FLAG_SYSTEM
            }
        val intent =
            if (Build.VERSION.SDK_INT >= 33) {
                Intent(MediaStore.ACTION_PICK_IMAGES)
            } else {
                Intent(Intent.ACTION_GET_CONTENT).setType("image/*").addCategory(Intent.CATEGORY_OPENABLE)
            }
        wallpaperResult = result
        try {
            host.startActivityForResult(intent, WALLPAPER_REQUEST)
        } catch (e: Exception) {
            wallpaperResult = null
            result.success(false)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == SAVE_FILE_REQUEST || requestCode == OPEN_FILE_REQUEST) {
            finishFileDialog(requestCode, resultCode, data)
            return true
        }
        if (requestCode != WALLPAPER_REQUEST) return false
        val result = wallpaperResult ?: return true
        wallpaperResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        val flags = wallpaperFlags
        background(result) {
            context.contentResolver.openInputStream(uri)?.use { stream ->
                WallpaperManager.getInstance(context).setStream(stream, null, true, flags)
                true
            } ?: false
        }
        return true
    }

    private companion object {
        const val TAG = "TurboLaunch"
        // Time for the window manager to settle between the pair's steps; tuned on device.
        const val PAIR_STEP_MILLIS = 600L
        const val WALLPAPER_REQUEST = 0x7a11
        const val SAVE_FILE_REQUEST = 0x7a12
        const val OPEN_FILE_REQUEST = 0x7a13
    }

    /**
     * True when `adb shell setprop debug.turbolaunch.bench 1` was run before
     * the app started: tool/bench_android.sh then reads timings from the log.
     */
    private fun benchMode(): Boolean = try {
        Class.forName("android.os.SystemProperties")
            .getMethod("get", String::class.java)
            .invoke(null, "debug.turbolaunch.bench") == "1"
    } catch (e: Exception) {
        false
    }
}
