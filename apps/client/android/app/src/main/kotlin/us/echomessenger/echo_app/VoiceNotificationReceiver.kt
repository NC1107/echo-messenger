package us.echomessenger.echo_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Receives Mute / Leave action taps from the voice-mode foreground
 * notification.  The receiver itself just forwards the action to
 * [MainActivity] (when alive) over a static bridge — Dart is the source
 * of truth for mic + room state.  If the activity is not running we
 * still update the notification optimistically so the UI is responsive,
 * and Dart will catch up the next time it observes the service.
 */
class VoiceNotificationReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_TOGGLE_MUTE = "us.echomessenger.echo_app.action.TOGGLE_MUTE"
        const val ACTION_LEAVE = "us.echomessenger.echo_app.action.LEAVE"
        const val EXTRA_NEW_MUTED = "new_muted"
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_TOGGLE_MUTE -> {
                val newMuted = intent.getBooleanExtra(EXTRA_NEW_MUTED, false)
                MainActivity.dispatchVoiceNotificationAction("mute", mapOf("muted" to newMuted))
            }
            ACTION_LEAVE -> {
                MainActivity.dispatchVoiceNotificationAction("leave", emptyMap())
            }
        }
    }
}
