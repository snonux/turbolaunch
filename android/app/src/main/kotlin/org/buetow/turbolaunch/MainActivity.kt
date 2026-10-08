package org.buetow.turbolaunch

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode

class MainActivity : FlutterActivity() {
    // A transparent Flutter surface lets the system wallpaper show through.
    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent
}
