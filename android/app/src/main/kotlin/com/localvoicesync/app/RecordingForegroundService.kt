package com.localvoicesync.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * 录音期间的前台服务。
 *
 * 存在的唯一理由：Android 10+ 对后台应用访问麦克风有严格限制，
 * 没有前台服务的话，息屏几分钟后系统会直接掐掉录音流，
 * 用户看到的却是"还在录"——这比直接报错更糟。
 *
 * 注意：本服务不自己录音，只负责把进程标记为 foreground。
 * 真正的录音仍然由 Dart 侧的 record 插件完成。
 */
class RecordingForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "lvs_recording"
        private const val CHANNEL_NAME = "录音状态"
        private const val NOTIFICATION_ID = 4711
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_BODY = "body"

        fun start(context: Context, title: String, body: String) {
            val intent = Intent(context, RecordingForegroundService::class.java).apply {
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_BODY, body)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, RecordingForegroundService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "正在录音"
        val body = intent?.getStringExtra(EXTRA_BODY) ?: ""
        ensureChannel()
        startForeground(NOTIFICATION_ID, buildNotification(title, body))
        // 进程被杀后不自动重启：录音流已经没了，重启一个空服务只会误导用户。
        return START_NOT_STICKY
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "录音进行中的常驻提示"
            setShowBadge(false)
            enableVibration(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(title: String, body: String): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }
}
