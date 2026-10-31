package com.localvoicesync.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "localvoicesync/foreground"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val title = call.argument<String>("title") ?: "正在录音"
                    val body = call.argument<String>("body") ?: ""
                    try {
                        RecordingForegroundService.start(this, title, body)
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("FG_START_FAILED", error.message, null)
                    }
                }

                "stop" -> {
                    try {
                        RecordingForegroundService.stop(this)
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("FG_STOP_FAILED", error.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }
}
