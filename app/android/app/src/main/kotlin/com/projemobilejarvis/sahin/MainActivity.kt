package com.projemobilejarvis.sahin

import android.content.Intent
import android.provider.Settings
import android.text.TextUtils
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter <-> Kotlin köprüsü.
 *  - accessibility kanalı (Faz 7): WhatsApp servisi durumu + onaylı gönderim.
 *  - mic kanalı (Faz 11): native MicAssistantService'i başlat/durdur/elle-tetikle + keyterms.
 *  - command EventChannel: native servisin çözdüğü komut metni ÖN PLANDA Flutter'a akar.
 */
class MainActivity : FlutterActivity() {
    private val accChannel = "com.projemobilejarvis.sahin/accessibility"
    private val micChannel = "com.projemobilejarvis.sahin/mic"
    private val cmdChannel = "com.projemobilejarvis.sahin/command"

    companion object {
        @Volatile var isForeground: Boolean = false
        @Volatile var commandSink: EventChannel.EventSink? = null
    }

    override fun onResume() { super.onResume(); isForeground = true }
    override fun onPause() { isForeground = false; super.onPause() }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // --- Erişilebilirlik (WhatsApp) ---
        MethodChannel(messenger, accChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "isServiceEnabled" -> result.success(isAccessibilityServiceEnabled())
                "openAccessibilitySettings" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(true)
                }
                "sendWhatsApp" -> {
                    val svc = WhatsAppAccessibilityService.instance
                    val phone = call.argument<String>("phone")
                    val text = call.argument<String>("text")
                    when {
                        svc == null -> result.error("SERVICE_OFF", "Erişilebilirlik servisi kapalı", null)
                        phone.isNullOrBlank() || text == null -> result.error("BAD_ARGS", "phone/text eksik", null)
                        else -> { svc.sendMessage(phone, text); result.success(true) }
                    }
                }
                else -> result.notImplemented()
            }
        }

        // --- Native mic servisi (Vosk wake + komut) ---
        MethodChannel(messenger, micChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "startMic" -> {
                    val i = Intent(this, MicAssistantService::class.java).apply {
                        action = MicAssistantService.ACTION_START
                        putExtra(MicAssistantService.EXTRA_BACKEND, call.argument<String>("backend") ?: "")
                        putExtra(MicAssistantService.EXTRA_KEY, call.argument<String>("apikey") ?: "")
                        putExtra(MicAssistantService.EXTRA_KEYTERMS, call.argument<String>("keyterms") ?: "")
                    }
                    startForegroundService(i) // Activity görünürken çağrılır (Android 14 mic kuralı)
                    result.success(true)
                }
                "captureNow" -> {
                    startService(Intent(this, MicAssistantService::class.java)
                        .apply { action = MicAssistantService.ACTION_CAPTURE })
                    result.success(true)
                }
                "setKeyterms" -> {
                    startService(Intent(this, MicAssistantService::class.java).apply {
                        action = MicAssistantService.ACTION_START
                        putExtra(MicAssistantService.EXTRA_KEYTERMS, call.argument<String>("keyterms") ?: "")
                    })
                    result.success(true)
                }
                "stopMic" -> {
                    startService(Intent(this, MicAssistantService::class.java)
                        .apply { action = MicAssistantService.ACTION_STOP })
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // --- Komut akışı (ön plan): native servis -> Flutter ---
        EventChannel(messenger, cmdChannel).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { commandSink = sink }
            override fun onCancel(args: Any?) { commandSink = null }
        })
    }

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
