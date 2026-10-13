package com.dshmobile.dsh_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * 定时任务的“保活”前台服务。
 *
 * 为什么需要它：定时任务到点要真的跑一次模型，而 Android 在没有前台服务时
 * 会很快回收后台进程 —— 进程一没，App 内的调度器（Dart 侧的 ScheduleRunner）
 * 就什么都不做。本服务只做一件事：**带一个常驻通知把自己挂成前台**，
 * 让进程活着；真正的调度与执行仍在 Dart 侧。
 *
 * 如实记录的能力边界（不要在交付里说成“一定能后台运行”）：
 *  - 前台服务类型用 dataSync。**Android 14 (API 34) 起，dataSync 类型有
 *    每 24 小时约 6 小时的累计运行上限**，超时后系统会停掉它。要突破这个上限
 *    需要改用 specialUse 并声明 PROPERTY_SPECIAL_USE_FGS_SUBTYPE（本 App 未做）。
 *  - 用户从“最近任务”里划掉 App、或被 ROM 的省电策略杀掉时，仍然会停；
 *    恢复后 Dart 侧会把错过的计划如实记成“已错过”。
 *  - Android 13+ 需要 POST_NOTIFICATIONS 权限，否则常驻通知不可见
 *    （服务本身仍会运行）。
 */
class DshSchedulerService : Service() {

    companion object {
        private const val TAG = "DshLocal"
        private const val CHANNEL_ID = "dsh_scheduler"
        private const val NOTIFICATION_ID = 4711
        private const val EXTRA_COUNT = "count"

        /** 启动/更新：count = 已启用的任务数（<=0 表示直接停掉）。 */
        fun start(context: Context, count: Int) {
            val intent = Intent(context, DshSchedulerService::class.java)
                .putExtra(EXTRA_COUNT, count)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Throwable) {
                // 后台启动前台服务在部分 ROM 上会被拒（IllegalStateException），
                // 这不是“代码坏了”，而是系统限制 —— 记日志，不崩 App。
                Log.w(TAG, "startForegroundService 被拒: ${e.message}")
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, DshSchedulerService::class.java))
            } catch (e: Throwable) {
                Log.w(TAG, "stopService 失败: ${e.message}")
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val count = intent?.getIntExtra(EXTRA_COUNT, 0) ?: 0
        if (count <= 0) {
            Log.i(TAG, "scheduler service: 没有已启用任务，停止")
            stopSelf()
            return START_NOT_STICKY
        }
        createChannel()
        val notification = buildNotification(count)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            Log.i(TAG, "scheduler service 已启动为前台，启用任务数=$count")
        } catch (e: Throwable) {
            Log.e(TAG, "startForeground 失败: ${e.message}")
            stopSelf()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        Log.i(TAG, "scheduler service 结束")
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "定时任务",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "定时任务运行时显示，用来把 App 留在后台"
            setShowBadge(false)
        }
        nm.createNotificationChannel(channel)
    }

    private fun buildNotification(count: Int): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("定时任务运行中")
            .setContentText("已启用 $count 个任务 · 点开查看")
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setOngoing(true)
            .setContentIntent(open)
            .build()
    }
}
