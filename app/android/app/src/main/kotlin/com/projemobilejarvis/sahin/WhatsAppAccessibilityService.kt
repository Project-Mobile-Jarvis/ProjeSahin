package com.projemobilejarvis.sahin

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.graphics.Rect
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Faz 7 — WhatsApp otomatik gönder (root'suz, AccessibilityService).
 *
 * Akış: Flutter SESLİ ONAYDAN SONRA sendMessage() çağırır → wa.me intent ile sohbet
 * metin DOLU açılır → bu servis sohbet ekranını yakalar, GÖNDER düğmesini bulur ve tıklar.
 *
 * Güvenlik: 'pendingSend' (armed) yoksa hiçbir şeye dokunmaz — yani kullanıcı onayı
 * dışında asla mesaj göndermez. Gönderdikten sonra kendini disarm eder (tek seferlik).
 *
 * Sağlamlık (SPEC: WhatsApp arayüzü değişince kırılabilir): gönder düğmesini 3 katmanlı
 * bulur — (1) viewId, (2) çok-dilli content-description, (3) sağ-alt tıklanabilir heuristik;
 * tıklama performAction → tıklanabilir ata → dispatchGesture sırasıyla denenir; düğüm geç
 * göründüğü için kısa aralıklarla yeniden denenir.
 */
class WhatsAppAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: WhatsAppAccessibilityService? = null
        private const val WA = "com.whatsapp"
        // content-description cihaz diline göre değişir → çok-dilli liste, küçük harf + contains.
        private val SEND_DESCS = listOf("gönder", "gonder", "send", "enviar", "senden", "envoyer", "invia")
        private const val MAX_ATTEMPTS = 12
    }

    private val handler = Handler(Looper.getMainLooper())
    @Volatile private var pendingSend = false
    private var attempts = 0

    override fun onServiceConnected() {
        instance = this
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onInterrupt() {}

    /** Flutter -> onaylı gönderim: sohbeti metin dolu aç ve gönder düğmesine basmak için 'arm' et. */
    fun sendMessage(phoneDigits: String, text: String) {
        pendingSend = true
        attempts = 0
        val uri = Uri.parse("https://wa.me/$phoneDigits?text=${Uri.encode(text)}")
        startActivity(
            Intent(Intent.ACTION_VIEW, uri).apply {
                setPackage(WA)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        )
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        event ?: return
        if (!pendingSend) return                       // onay yoksa dokunma
        if (event.packageName != WA) return            // sadece WhatsApp
        when (event.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED -> {
                if (!isOnChatScreen()) return          // ana liste/ayarlar değil, sohbet ekranı mı?
                attempts = 0
                tryClickSendWithRetry()
            }
        }
    }

    /** Mesaj kutusu/başlık (viewId) ya da herhangi bir editable alan varsa sohbet ekranındayız. */
    private fun isOnChatScreen(): Boolean {
        val root = rootInActiveWindow ?: return false
        if (root.findAccessibilityNodeInfosByViewId("$WA:id/entry").isNotEmpty()) return true
        if (root.findAccessibilityNodeInfosByViewId("$WA:id/conversation_contact_name").isNotEmpty()) return true
        return hasEditable(root) // viewId değişse de mesaj kutusu (editable) varsa sohbetteyiz
    }

    private fun hasEditable(node: AccessibilityNodeInfo?): Boolean {
        node ?: return false
        if (node.isEditable) return true
        for (i in 0 until node.childCount) {
            if (hasEditable(node.getChild(i))) return true
        }
        return false
    }

    private fun tryClickSendWithRetry() {
        if (!pendingSend) return
        val node = findSendNode()
        if (node != null && clickNodeOrAncestorOrGesture(node)) {
            pendingSend = false                        // tek seferlik: gönderildi, dur
            attempts = 0
            return
        }
        if (attempts++ < MAX_ATTEMPTS) {
            handler.postDelayed({ tryClickSendWithRetry() }, 250) // düğüm henüz görünmedi → tekrar
        } else {
            pendingSend = false                        // pes et
        }
    }

    /** 3 katmanlı: viewId → content-desc → sağ-alt tıklanabilir heuristik. */
    private fun findSendNode(): AccessibilityNodeInfo? {
        val root = rootInActiveWindow ?: return null
        root.findAccessibilityNodeInfosByViewId("$WA:id/send").firstOrNull()?.let { return it }
        findByContentDesc(root)?.let { return it }
        return findBottomRightClickable(root)
    }

    private fun findByContentDesc(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        node ?: return null
        val desc = node.contentDescription?.toString()?.lowercase()
        if (desc != null && SEND_DESCS.any { desc.contains(it) }) return node
        for (i in 0 until node.childCount) {
            findByContentDesc(node.getChild(i))?.let { return it }
        }
        return null
    }

    private fun findBottomRightClickable(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        var best: AccessibilityNodeInfo? = null
        var bestScore = Int.MIN_VALUE
        val r = Rect()
        fun walk(n: AccessibilityNodeInfo?) {
            n ?: return
            val cls = n.className?.toString() ?: ""
            if (n.isClickable && (cls.contains("Button") || cls.contains("Image"))) {
                n.getBoundsInScreen(r)
                val score = r.right + r.bottom         // sağ-alt köşeye yakınlık
                if (score > bestScore) {
                    bestScore = score
                    best = n
                }
            }
            for (i in 0 until n.childCount) walk(n.getChild(i))
        }
        walk(root)
        return best
    }

    /** Tıkla → değilse tıklanabilir ata → değilse koordinata gerçek dokunuş (gesture). */
    private fun clickNodeOrAncestorOrGesture(node: AccessibilityNodeInfo): Boolean {
        var n: AccessibilityNodeInfo? = node
        while (n != null) {
            if (n.isClickable && n.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true
            n = n.parent
        }
        val r = Rect()
        node.getBoundsInScreen(r)
        if (r.width() <= 0 || r.height() <= 0) return false
        val path = Path().apply { moveTo(r.exactCenterX(), r.exactCenterY()) }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 50))
            .build()
        return dispatchGesture(gesture, null, null)
    }
}
