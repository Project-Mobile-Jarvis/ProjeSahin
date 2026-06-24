package com.projemobilejarvis.sahin

import android.content.Intent
import android.provider.Settings
import android.text.TextUtils
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter <-> Kotlin köprüsü (Faz 7). Erişilebilirlik servisinin durumunu sorgular,
 * ayar ekranını açar ve onaylı WhatsApp gönderimini tetikler.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "com.projemobilejarvis.sahin/accessibility"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isServiceEnabled" -> result.success(isAccessibilityServiceEnabled())

                    "openAccessibilitySettings" -> {
                        startActivity(
                            Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(true)
                    }

                    "sendWhatsApp" -> {
                        val svc = WhatsAppAccessibilityService.instance
                        val phone = call.argument<String>("phone")
                        val text = call.argument<String>("text")
                        when {
                            svc == null ->
                                result.error("SERVICE_OFF", "Erişilebilirlik servisi kapalı", null)
                            phone.isNullOrBlank() || text == null ->
                                result.error("BAD_ARGS", "phone/text eksik", null)
                            else -> {
                                svc.sendMessage(phone, text)
                                result.success(true)
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /** ENABLED_ACCESSIBILITY_SERVICES içinde bizim servis var mı (ComponentName ile, naif contains değil). */
    private fun isAccessibilityServiceEnabled(): Boolean {
        val expected = "$packageName/$packageName.WhatsAppAccessibilityService"
        val enabled = Settings.Secure.getString(
            contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        val splitter = TextUtils.SimpleStringSplitter(':')
        splitter.setString(enabled)
        while (splitter.hasNext()) {
            if (splitter.next().equals(expected, ignoreCase = true)) return true
        }
        return false
    }
}
