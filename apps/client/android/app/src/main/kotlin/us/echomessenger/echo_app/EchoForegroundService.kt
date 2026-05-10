package us.echomessenger.echo_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Foreground service that keeps the app alive in the background.
 *
 * Supports two modes:
 *
 *   - **Keep-alive mode** (default): generic notification, type DATA_SYNC.
 *     Used so the WebSocket stays connected for incoming messages.
 *
 *   - **Voice mode**: notification shows the active channel name + Mute /
 *     Leave actions, type MICROPHONE | MEDIA_PLAYBACK so Android 14+ does
 *     not revoke RECORD_AUDIO when the app is backgrounded.  Started by
 *     LiveKitVoiceProvider.joinChannel via the BackgroundService method
 *     channel; stopped on leaveChannel.
 *
 * Mute / Leave actions are routed back to Dart via a static broadcast
 * channel held by [MainActivity] (see [VoiceNotificationReceiver]).
 */
class EchoForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "echo_foreground"
        const val NOTIFICATION_ID = 1

        // Intent extras used to start / update the voice notification.
        const val EXTRA_MODE = "mode"
        const val EXTRA_CHANNEL_NAME = "channel_name"
        const val EXTRA_IS_MUTED = "is_muted"
        const val EXTRA_PARTICIPANT_COUNT = "participant_count"

        // Mode values.
        const val MODE_KEEPALIVE = "keepalive"
        const val MODE_VOICE = "voice"
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var currentMode: String = MODE_KEEPALIVE
    private var voiceChannelName: String = ""
    private var voiceIsMuted: Boolean = false
    private var voiceParticipantCount: Int = 1

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A null intent here means the service was restarted by the system
        // after being killed; fall back to keep-alive defaults.
        val mode = intent?.getStringExtra(EXTRA_MODE) ?: currentMode
        currentMode = mode

        if (mode == MODE_VOICE) {
            voiceChannelName = intent?.getStringExtra(EXTRA_CHANNEL_NAME) ?: voiceChannelName
            voiceIsMuted = intent?.getBooleanExtra(EXTRA_IS_MUTED, voiceIsMuted) ?: voiceIsMuted
            voiceParticipantCount = intent?.getIntExtra(EXTRA_PARTICIPANT_COUNT, voiceParticipantCount)
                ?: voiceParticipantCount
        }

        val notification = buildNotification()
        startInForegroundMode(notification)

        if (wakeLock == null) {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "echo:foreground_service"
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        }

        return START_STICKY
    }

    private fun startInForegroundMode(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val type = if (currentMode == MODE_VOICE) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            } else {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            }
            startForeground(NOTIFICATION_ID, notification, type)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // User swiped the app from recents — drop the notification cleanly
        // so we don't leak a zombie wakelock or stuck "Connected" badge.
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Background Connection",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps Echo connected for real-time messages and voice"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val title: String
        val body: String
        val builder = Notification.Builder(this, CHANNEL_ID)

        if (currentMode == MODE_VOICE) {
            title = if (voiceChannelName.isNotEmpty()) voiceChannelName else "Voice call"
            body = if (voiceParticipantCount > 1) {
                "Connected · $voiceParticipantCount in lounge"
            } else {
                "Connected"
            }
            builder.addAction(buildMuteAction())
            builder.addAction(buildLeaveAction())
        } else {
            title = "Echo Messenger"
            body = "Connected and receiving messages"
        }

        return builder
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    private fun buildMuteAction(): Notification.Action {
        val label = if (voiceIsMuted) "Unmute" else "Mute"
        val icon = if (voiceIsMuted) {
            android.R.drawable.ic_lock_silent_mode_off
        } else {
            android.R.drawable.ic_lock_silent_mode
        }
        val intent = Intent(this, VoiceNotificationReceiver::class.java).apply {
            action = VoiceNotificationReceiver.ACTION_TOGGLE_MUTE
            // Pass the desired post-toggle state so the UI matches even if
            // the broadcast races a state read.
            putExtra(VoiceNotificationReceiver.EXTRA_NEW_MUTED, !voiceIsMuted)
        }
        val pending = PendingIntent.getBroadcast(
            this, 1, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Action.Builder(icon, label, pending).build()
    }

    private fun buildLeaveAction(): Notification.Action {
        val intent = Intent(this, VoiceNotificationReceiver::class.java).apply {
            action = VoiceNotificationReceiver.ACTION_LEAVE
        }
        val pending = PendingIntent.getBroadcast(
            this, 2, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Action.Builder(
            android.R.drawable.ic_menu_close_clear_cancel,
            "Leave",
            pending
        ).build()
    }
}
