package us.echomessenger.echo_app

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "us.echomessenger/foreground_service"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    startForegroundService()
                    result.success(null)
                }
                "stop" -> {
                    stopForegroundService()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startForegroundService() {
        val intent = Intent(this, EchoForegroundService::class.java)
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
}
