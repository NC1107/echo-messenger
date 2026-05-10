package us.echomessenger.echo_app

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter UI plus three method-channel surfaces:
 *
 *   - `us.echomessenger/foreground_service` — start/stop/update the
 *     [EchoForegroundService] (keep-alive and voice modes), and forward
 *     Mute / Leave taps from the voice notification back to Dart.
 *   - `us.echomessenger/pip` — track the current screen-share aspect
 *     ratio; on home-button press, enter PiP if eligible.  Runtime gate
 *     keeps minSdk at 24 (Android 7.x users skip PiP).
 *   - `us.echomessenger/push` — owned by AppDelegate-equivalent on iOS;
 *     left alone here.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val FG_CHANNEL = "us.echomessenger/foreground_service"
        private const val PIP_CHANNEL = "us.echomessenger/pip"

        // Static bridge so VoiceNotificationReceiver can deliver Mute /
        // Leave taps without binding to the running activity.  When the
        // activity is not alive (rare — the app is foregrounded by tap
        // before the action takes effect), the dispatch is a no-op.
        @Volatile
        private var foregroundChannel: MethodChannel? = null

        fun dispatchVoiceNotificationAction(
            action: String,
            args: Map<String, Any?>
        ) {
            // MethodChannel.invokeMethod must run on the platform thread;
            // FlutterEngine handles the post internally.
            foregroundChannel?.invokeMethod(
                "onNotificationAction",
                mapOf("action" to action) + args
            )
        }
    }

    private var pipEligibleWidth: Int = 0
    private var pipEligibleHeight: Int = 0
    private var pipChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val fgChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FG_CHANNEL
        )
        foregroundChannel = fgChannel
        fgChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    startKeepaliveService()
                    result.success(null)
                }
                "stop" -> {
                    stopForegroundService()
                    result.success(null)
                }
                "startVoice" -> {
                    val channelName = call.argument<String>("channelName") ?: ""
                    val isMuted = call.argument<Boolean>("isMuted") ?: false
                    val participantCount = call.argument<Int>("participantCount") ?: 1
                    startVoiceService(channelName, isMuted, participantCount)
                    result.success(null)
                }
                "updateVoice" -> {
                    val channelName = call.argument<String>("channelName")
                    val isMuted = call.argument<Boolean>("isMuted")
                    val participantCount = call.argument<Int>("participantCount")
                    updateVoiceService(channelName, isMuted, participantCount)
                    result.success(null)
                }
                "stopVoice" -> {
                    stopForegroundService()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        val pip = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PIP_CHANNEL
        )
        pipChannel = pip
        pip.setMethodCallHandler { call, result ->
            when (call.method) {
                "setEligible" -> {
                    val w = call.argument<Int>("width") ?: 0
                    val h = call.argument<Int>("height") ?: 0
                    pipEligibleWidth = w
                    pipEligibleHeight = h
                    result.success(null)
                }
                "enterPip" -> {
                    result.success(enterPipIfEligible())
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // User pressed Home / opened recents — try to drop into PiP if a
        // remote screen share is active.  No-op on Android < O.
        enterPipIfEligible()
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("onPipChanged", mapOf("inPip" to isInPictureInPictureMode))
    }

    private fun enterPipIfEligible(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        if (pipEligibleWidth <= 0 || pipEligibleHeight <= 0) return false
        return try {
            val rational = clampedRational(pipEligibleWidth, pipEligibleHeight)
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(rational)
                .build()
            enterPictureInPictureMode(params)
        } catch (e: IllegalStateException) {
            // Activity may already be paused or destroyed.
            false
        } catch (e: IllegalArgumentException) {
            // Aspect ratio outside [0.418, 2.39] — Android rejects it.
            false
        }
    }

    /**
     * Android's PiP API rejects aspect ratios outside roughly [1:2.39, 2.39:1].
     * Most screen shares are wider than 2.39:1 only on multi-monitor setups;
     * clamp to the nearest valid ratio so the user still gets a window.
     */
    private fun clampedRational(width: Int, height: Int): Rational {
        val raw = width.toDouble() / height.toDouble()
        val clamped = raw.coerceIn(0.42, 2.38)
        // Multiply through to keep integer rationals (Rational uses ints).
        val w = (clamped * 1000).toInt().coerceAtLeast(1)
        val h = 1000
        return Rational(w, h)
    }

    private fun startKeepaliveService() {
        val intent = Intent(this, EchoForegroundService::class.java).apply {
            putExtra(EchoForegroundService.EXTRA_MODE, EchoForegroundService.MODE_KEEPALIVE)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun startVoiceService(channelName: String, isMuted: Boolean, participantCount: Int) {
        val intent = Intent(this, EchoForegroundService::class.java).apply {
            putExtra(EchoForegroundService.EXTRA_MODE, EchoForegroundService.MODE_VOICE)
            putExtra(EchoForegroundService.EXTRA_CHANNEL_NAME, channelName)
            putExtra(EchoForegroundService.EXTRA_IS_MUTED, isMuted)
            putExtra(EchoForegroundService.EXTRA_PARTICIPANT_COUNT, participantCount)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun updateVoiceService(
        channelName: String?,
        isMuted: Boolean?,
        participantCount: Int?
    ) {
        // onStartCommand picks up the latest extras and rebuilds the
        // notification.  Falls back to the service's stored values for
        // any extras left null.
        val intent = Intent(this, EchoForegroundService::class.java).apply {
            putExtra(EchoForegroundService.EXTRA_MODE, EchoForegroundService.MODE_VOICE)
            channelName?.let { putExtra(EchoForegroundService.EXTRA_CHANNEL_NAME, it) }
            isMuted?.let { putExtra(EchoForegroundService.EXTRA_IS_MUTED, it) }
            participantCount?.let { putExtra(EchoForegroundService.EXTRA_PARTICIPANT_COUNT, it) }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopForegroundService() {
        val intent = Intent(this, EchoForegroundService::class.java)
        stopService(intent)
    }

    override fun onDestroy() {
        super.onDestroy()
        foregroundChannel = null
        pipChannel = null
    }
}
