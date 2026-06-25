package com.projemobilejarvis.sahin

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer
import org.vosk.android.StorageService
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Faz 11 — Mic'in TEK sahibi native foreground servis.
 *  - Tek AudioRecord (16kHz mono) sürekli okur, hiç kapanmaz.
 *  - WAKE: Vosk (grammar ["şahin","[unk]"]) ile "Şahin" yakalanır (hızlı, az yanlış-tetik).
 *  - COMMAND: aynı akıştan komut PCM'i biriktirilir; Vosk endpoint'i (sessizlik) ile biter.
 *  - Komut sesi WAV → BIZIM /stt'ye (X-API-Key) POST → Deepgram metni.
 *  - Metin Flutter'a: ön planda EventChannel, kapalıyken SharedPreferences + uygulamayı aç.
 *
 * Vosk SADECE wake için; komut transkripsiyonu Deepgram (backend). Mic juggling YOK.
 */
class MicAssistantService : Service() {

    companion object {
        const val ACTION_START = "start"
        const val ACTION_CAPTURE = "capture" // butondan elle tetikleme
        const val ACTION_STOP = "stop"
        const val EXTRA_BACKEND = "backend"
        const val EXTRA_KEY = "apikey"
        const val EXTRA_KEYTERMS = "keyterms"

        @Volatile var instance: MicAssistantService? = null
        private const val NOTIF_ID = 261
        private const val CH_ID = "sahin_wake"
        private const val SR = 16000
        private val WAKE_WORDS = listOf("şahin", "sahin", "şahım", "şahin")
        private const val WAKE_GRAMMAR = "[\"şahin\", \"sahin\", \"[unk]\"]"
    }

    private enum class St { WAKE, COMMAND }

    @Volatile private var running = false
    @Volatile private var forceCapture = false // buton: wake beklemeden komuta gir
    private var model: Model? = null
    private var micThread: Thread? = null
    private val http = OkHttpClient.Builder()
        .callTimeout(30, TimeUnit.SECONDS).build()

    private var backendUrl = ""
    private var apiKey = ""
    @Volatile private var keyterms = ""

    override fun onBind(i: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> { stopSelf(); return START_NOT_STICKY }
            ACTION_CAPTURE -> { forceCapture = true; return START_STICKY }
        }
        // start / yeniden başlatma
        intent?.getStringExtra(EXTRA_BACKEND)?.let { if (it.isNotEmpty()) backendUrl = it }
        intent?.getStringExtra(EXTRA_KEY)?.let { if (it.isNotEmpty()) apiKey = it }
        intent?.getStringExtra(EXTRA_KEYTERMS)?.let { keyterms = it }

        startAsForeground()
        instance = this
        if (model == null) {
            StorageService.unpack(
                this, "model/vosk-model-small-tr-0.3", "vosk-tr",
                { m -> model = m; startLoop() },
                { _ -> updateNotif("Model yüklenemedi") }
            )
        } else {
            startLoop()
        }
        return START_STICKY
    }

    private fun startLoop() {
        if (running) return
        running = true
        micThread = thread(name = "sahin-mic") { micLoop() }
    }

    private fun micLoop() {
        val m = model ?: return
        val minBuf = AudioRecord.getMinBufferSize(
            SR, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        val chunk = Math.round(SR * 0.2f) // 200ms
        val recorder = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION, SR,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuf, chunk * 2)
            )
        } catch (e: Exception) {
            updateNotif("Mikrofon açılamadı"); return
        }

        val wakeRec = Recognizer(m, SR.toFloat(), WAKE_GRAMMAR)
        val cmdRec = Recognizer(m, SR.toFloat()) // varsayılan endpoint (sessizlikte acceptWaveForm==true)
        val buf = ShortArray(chunk)
        var state = St.WAKE
        val pcm = ByteArrayOutputStream()
        var cmdChunks = 0 // komut süresi (200ms'lik chunk) — endpoint gelmezse üst sınır

        recorder.startRecording()
        while (running) {
            val n = recorder.read(buf, 0, buf.size)
            if (n <= 0) continue

            if (state == St.WAKE && forceCapture) {
                // buton: wake'i atla, doğrudan komuta gir
                forceCapture = false
                state = St.COMMAND
                cmdRec.reset(); pcm.reset(); cmdChunks = 0
            }

            when (state) {
                St.WAKE -> {
                    val done = wakeRec.acceptWaveForm(buf, n)
                    val js = JSONObject(if (done) wakeRec.result else wakeRec.partialResult)
                    val txt = js.optString(if (done) "text" else "partial").lowercase()
                    if (WAKE_WORDS.any { txt.contains(it) }) {
                        state = St.COMMAND
                        wakeRec.reset(); cmdRec.reset(); pcm.reset(); cmdChunks = 0
                    }
                }
                St.COMMAND -> {
                    appendPcm(pcm, buf, n)
                    val end = cmdRec.acceptWaveForm(buf, n) // TRUE = Vosk endpoint (sessizlik)
                    if (end || ++cmdChunks > 45) { // endpoint VEYA ~9s üst sınır
                        val bytes = pcm.toByteArray()
                        state = St.WAKE
                        wakeRec.reset()
                        if (bytes.size > SR) { // en az ~0.5s ses varsa işle
                            thread { handleCommand(bytes) }
                        }
                    }
                }
            }
        }
        recorder.stop(); recorder.release()
        wakeRec.close(); cmdRec.close()
    }

    private fun handleCommand(pcm: ByteArray) {
        val wav = writeWav(pcm)
        val text = try { postStt(wav) } catch (e: Exception) { "" } finally { wav.delete() }
        if (text.isBlank()) return
        deliverToFlutter(text)
    }

    /** Komut sesini BIZIM /stt'ye gönderir (X-API-Key; Deepgram'a değil → anahtar backend'de). */
    private fun postStt(wav: File): String {
        if (backendUrl.isEmpty() || apiKey.isEmpty()) return ""
        val body = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("file", "audio.wav", wav.asRequestBody("audio/wav".toMediaType()))
            .addFormDataPart("keyterms", keyterms)
            .build()
        val req = Request.Builder()
            .url("$backendUrl/stt")
            .addHeader("X-API-Key", apiKey)
            .post(body)
            .build()
        http.newCall(req).execute().use { r ->
            val s = r.body?.string() ?: return ""
            return JSONObject(s).optString("text", "").trim()
        }
    }

    private fun deliverToFlutter(text: String) {
        if (MainActivity.isForeground && MainActivity.commandSink != null) {
            Handler(Looper.getMainLooper()).post { MainActivity.commandSink?.success(text) }
        } else {
            // arka plan/kapalı: Flutter shared_preferences anahtarı 'flutter.' önekli
            getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .edit().putString("flutter.pending_command", text).apply()
            val i = Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            try { startActivity(i) } catch (_: Exception) {}
        }
    }

    private fun appendPcm(out: ByteArrayOutputStream, buf: ShortArray, n: Int) {
        val b = ByteArray(n * 2)
        for (i in 0 until n) {
            b[i * 2] = (buf[i].toInt() and 0xff).toByte()
            b[i * 2 + 1] = ((buf[i].toInt() shr 8) and 0xff).toByte()
        }
        out.write(b)
    }

    private fun writeWav(pcm: ByteArray): File {
        val f = File(cacheDir, "cmd.wav")
        RandomAccessFile(f, "rw").use { raf ->
            raf.setLength(0)
            val total = pcm.size
            val byteRate = SR * 2
            raf.writeBytes("RIFF")
            raf.writeInt(Integer.reverseBytes(36 + total))
            raf.writeBytes("WAVE"); raf.writeBytes("fmt ")
            raf.writeInt(Integer.reverseBytes(16))
            raf.writeShort(java.lang.Short.reverseBytes(1.toShort()).toInt())   // PCM
            raf.writeShort(java.lang.Short.reverseBytes(1.toShort()).toInt())   // mono
            raf.writeInt(Integer.reverseBytes(SR))
            raf.writeInt(Integer.reverseBytes(byteRate))
            raf.writeShort(java.lang.Short.reverseBytes(2.toShort()).toInt())   // block align
            raf.writeShort(java.lang.Short.reverseBytes(16.toShort()).toInt())  // bits
            raf.writeBytes("data")
            raf.writeInt(Integer.reverseBytes(total))
            raf.write(pcm)
        }
        return f
    }

    private fun startAsForeground() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CH_ID, "Şahin dinliyor", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val notif = buildNotif("\"Şahin\" de — seni dinliyorum")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    private fun buildNotif(text: String): Notification =
        Notification.Builder(this, CH_ID)
            .setContentTitle("Şahin aktif")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .build()

    private fun updateNotif(text: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIF_ID, buildNotif(text))
    }

    private fun postMain(block: () -> Unit) = Handler(Looper.getMainLooper()).post(block)

    override fun onDestroy() {
        running = false
        instance = null
        micThread?.join(500)
        model?.close()
        super.onDestroy()
    }
}
