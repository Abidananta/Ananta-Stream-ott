package com.ananta.ott

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Surface
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.net.HttpURLConnection
import java.net.URL


/**
 * Anti-sniffing guard. Packet-capture tools such as HTTP Canary work through an
 * on-device VPN (or a proxy) and read every URL the app opens. While one is
 * active, or a known capture app is installed, playback is refused so the
 * m3u8 / stream URLs are never requested through it.
 *
 * Honest limit: this is a deterrent, not a lock. Someone with root, Frida or a
 * re-packaged APK can still get around it. Real protection for a link is
 * server-side (https + signed, expiring URLs).
 */
object AnantaGuard {
    // Flip any of these to false if it blocks legitimate users.
    const val BLOCK_VPN = false           // true = refuse playback while ANY VPN is on
    const val BLOCK_PROXY = true          // system / JVM HTTP proxy (Charles, mitmproxy ...)
    const val BLOCK_CAPTURE_APPS = false  // true = refuse if a known capture app is installed

    // Keep in sync with <queries> added in .github/workflows/build-apk.yml.
    val CAPTURE_PACKAGES = listOf(
        "com.guoshi.httpcanary",
        "com.guoshi.httpcanary.premium",
        "app.greyshirts.sslcapture",
        "com.minhui.networkcapture",
        "com.emanuelef.remote_capture",
        "jp.co.taosoftware.android.packetcapture",
        "com.network.proxy"
    )

    private var cachedAt = 0L
    private var cached: String? = null

    /** Returns a human readable reason when playback must be blocked, else null. */
    @Synchronized
    fun check(ctx: Context): String? {
        val now = System.currentTimeMillis()
        if (now - cachedAt < 1500) return cached
        cached = compute(ctx)
        cachedAt = now
        return cached
    }

    private fun compute(ctx: Context): String? {
        try {
            if (BLOCK_VPN && vpnActive(ctx))
                return "BLOCKED: VPN / packet-capture is active. Turn it off and reopen the channel."
            if (BLOCK_PROXY && proxyActive(ctx))
                return "BLOCKED: network proxy detected. Turn it off and reopen the channel."
            if (BLOCK_CAPTURE_APPS) {
                for (pkg in CAPTURE_PACKAGES) {
                    val found = try {
                        ctx.packageManager.getPackageInfo(pkg, 0); true
                    } catch (e: Exception) { false }
                    if (found) return "BLOCKED: packet-capture app installed ($pkg). Uninstall it to watch."
                }
            }
        } catch (e: Exception) {
            // never block because the check itself failed
        }
        return null
    }

    private fun vpnActive(ctx: Context): Boolean {
        try {
            val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            if (Build.VERSION.SDK_INT >= 23) {
                val caps = cm.getNetworkCapabilities(cm.activeNetwork)
                if (caps != null && (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) ||
                        !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN))) return true
            }
        } catch (e: Exception) { /* fall through to interface scan */ }
        try {
            val ifs = java.net.NetworkInterface.getNetworkInterfaces() ?: return false
            for (nif in ifs) {
                if (!nif.isUp) continue
                val n = nif.name ?: continue
                if (n.startsWith("tun") || n.startsWith("ppp") || n.startsWith("pptp") || n.startsWith("tap")) return true
            }
        } catch (e: Exception) { }
        return false
    }

    private fun proxyActive(ctx: Context): Boolean {
        val host = System.getProperty("http.proxyHost")
        if (!host.isNullOrEmpty()) return true
        try {
            if (Build.VERSION.SDK_INT >= 23) {
                val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                if (!cm.defaultProxy?.host.isNullOrEmpty()) return true
            }
        } catch (e: Exception) { }
        return false
    }
}

/**
 * Short-link / redirect resolver. Links such as jmp2.uk, shorturl.at or
 * tinyurl.com have no ".m3u8" in the path, so ExoPlayer cannot tell it is an
 * HLS stream (and a plain redirect hop can also be an HTML page or a 200
 * response that carries the playlist itself). This follows the redirect
 * chain by hand (HTTP 3xx, <meta refresh>, simple JS redirects, a channel
 * list whose first entry is the real stream), works out the real URL and
 * stream type, and hands that to ExoPlayer.
 *
 * Direct links that already end in .m3u8 / .ts / .mpd ... are NOT touched.
 * If anything fails the original URL is played exactly as before.
 */
@androidx.annotation.OptIn(UnstableApi::class)
object AnantaUrlResolver {
    data class Result(val url: String, val mimeType: String?)

    private const val BROWSER_UA =
        "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) " +
            "Chrome/124.0.0.0 Mobile Safari/537.36"
    private const val MAX_HOPS = 10
    private const val TOTAL_BUDGET_MS = 9_000L
    private const val HEAD_BYTES = 64 * 1024

    private val DIRECT_EXT = listOf(
        ".m3u8", ".mpd", ".ts", ".mp4", ".mkv", ".aac", ".mp3", ".flv", ".webm", ".ism", ".isml"
    )

    private val META_REFRESH = Regex(
        "<meta[^>]+http-equiv\\s*=\\s*[\"']?refresh[\"']?[^>]*content\\s*=\\s*[\"'][^\"']*?url\\s*=\\s*['\"]?([^\"'>\\s]+)",
        RegexOption.IGNORE_CASE
    )
    private val JS_REDIRECT = Regex(
        "(?:(?:window|document|top|self)\\.)?location(?:\\.href)?\\s*=\\s*[\"']([^\"']+)[\"']|" +
            "location\\.(?:replace|assign)\\(\\s*[\"']([^\"']+)[\"']\\s*\\)",
        RegexOption.IGNORE_CASE
    )
    private val STREAM_IN_PAGE = Regex(
        "https?://[^\\s\"'<>\\\\]+?\\.(?:m3u8|mpd)(?:\\?[^\\s\"'<>\\\\]*)?",
        RegexOption.IGNORE_CASE
    )

    /** True when the URL already names a media file/manifest (no resolving needed). */
    fun looksDirect(url: String): Boolean {
        val path = try { URL(url).path ?: "" } catch (e: Exception) { url.substringBefore('?') }
        val p = path.lowercase()
        return DIRECT_EXT.any { p.endsWith(it) }
    }

    fun resolve(start: String, headers: Map<String, String>): Result {
        val deadline = System.currentTimeMillis() + TOTAL_BUDGET_MS
        // 1st pass with the app's own headers, 2nd pass pretending to be a browser
        // (some short-link sites only redirect real browsers).
        attempt(start, headers, deadline)?.let { return it }
        val browser = headers.filterKeys { !it.equals("User-Agent", true) } + ("User-Agent" to BROWSER_UA)
        attempt(start, browser, deadline)?.let { return it }
        return Result(start, null)
    }

    private fun attempt(start: String, headers: Map<String, String>, deadline: Long): Result? {
        var current = start
        var hops = 0
        while (hops < MAX_HOPS && System.currentTimeMillis() < deadline) {
            val conn = URL(current).openConnection() as HttpURLConnection
            try {
                conn.instanceFollowRedirects = false
                conn.connectTimeout = 6000
                conn.readTimeout = 6000
                conn.requestMethod = "GET"
                headers.forEach { (k, v) -> conn.setRequestProperty(k, v) }
                val code = conn.responseCode

                if (code in 300..399) {
                    val loc = conn.getHeaderField("Location")?.trim()
                    if (loc.isNullOrEmpty()) return null
                    current = URL(URL(current), loc).toString()
                    hops++
                    if (looksDirect(current)) return Result(current, null)
                    continue
                }
                if (code !in 200..299) return null

                val type = (conn.contentType ?: "").lowercase()
                val head = conn.inputStream.use { readHead(it, HEAD_BYTES) }
                val text = String(head, Charsets.UTF_8).trimStart('\uFEFF', ' ', '\t', '\r', '\n')

                // --- HLS playlist (or a plain channel list pointing at the stream)
                if (type.contains("mpegurl") || text.startsWith("#EXTM3U") || text.contains("#EXT-X-")) {
                    if (text.contains("#EXT-X-") || !text.contains("#EXTINF")) {
                        return Result(current, MimeTypes.APPLICATION_M3U8)
                    }
                    val first = text.lineSequence().map { it.trim() }
                        .firstOrNull { it.isNotEmpty() && !it.startsWith("#") } ?: return null
                    current = URL(URL(current), first).toString()
                    hops++
                    if (looksDirect(current)) return Result(current, null)
                    continue
                }
                // --- DASH
                if (type.contains("dash+xml") || text.contains("<MPD")) {
                    return Result(current, MimeTypes.APPLICATION_MPD)
                }
                // --- HTML page: meta refresh / JS redirect / stream URL inside the page
                if (type.contains("html") || text.startsWith("<")) {
                    val next = META_REFRESH.find(text)?.groupValues?.get(1)
                        ?: JS_REDIRECT.find(text)?.let { it.groupValues[1].ifEmpty { it.groupValues[2] } }
                        ?: STREAM_IN_PAGE.find(text)?.value
                    if (next.isNullOrEmpty()) return null
                    val decoded = next.replace("\\/", "/").replace("&amp;", "&")
                    current = URL(URL(current), decoded).toString()
                    hops++
                    if (looksDirect(current)) return Result(current, null)
                    continue
                }
                // --- anything else (video/mp2t, octet-stream, video/*, audio/*): let ExoPlayer sniff it
                return Result(current, null)
            } finally {
                try { conn.disconnect() } catch (_: Exception) {}
            }
        }
        return null
    }

    private fun readHead(input: java.io.InputStream, max: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buf = ByteArray(8192)
        while (out.size() < max) {
            val n = input.read(buf, 0, minOf(buf.size, max - out.size()))
            if (n <= 0) break
            out.write(buf, 0, n)
        }
        return out.toByteArray()
    }
}

/**
 * ExoPlayer (AndroidX Media3) playback engine for Ananta OTT - the same engine
 * family TiviMate uses. Video is rendered into a Flutter texture, so the whole
 * Flutter UI (overlays, PiP, TV remote handling) stays exactly as before.
 *
 * Tuned for IPTV: large live buffer, endless network retries, tolerant MPEG-TS
 * parsing, hardware decoders first with automatic software fallback, and the
 * FFmpeg audio decoder (when bundled) for MP2 / AC-3 / E-AC-3 / DTS / etc.
 */
@androidx.annotation.OptIn(UnstableApi::class)
class AnantaExo(
    private val context: Context,
    messenger: BinaryMessenger,
    private val textures: TextureRegistry
) {
    private val channel = MethodChannel(messenger, "com.ananta.ott/exo")
    private val main = Handler(Looper.getMainLooper())
    private val players = HashMap<Int, Instance>()
    private var nextId = 1

    /** Called on the main thread whenever any player's play/buffer state changes. */
    var onStateChanged: (() -> Unit)? = null
    /** Called with the visible aspect ratio (width/height) whenever a video size is known. */
    var onVideoAspect: ((Double) -> Unit)? = null

    /** True while at least one player is meant to be playing (PiP should be armed). */
    fun isActive(): Boolean = players.values.any { it.isWanted() }

    // While any player exists, re-check for VPN / capture tools and cut playback.
    private val guardTicker = object : Runnable {
        override fun run() {
            if (players.isNotEmpty()) {
                val reason = AnantaGuard.check(context)
                if (reason != null) {
                    players.keys.toList().forEach { pid ->
                        emit(pid, mapOf("type" to "error", "message" to reason))
                    }
                    releaseAll()
                }
            }
            main.postDelayed(this, 3000)
        }
    }

    init {
        channel.setMethodCallHandler { call, result -> handle(call, result) }
        main.postDelayed(guardTicker, 3000)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "create" -> {
                    AnantaGuard.check(context)?.let { reason ->
                        result.error("BLOCKED", reason, null)
                        return
                    }
                    val url = call.argument<String>("url")
                    if (url.isNullOrEmpty()) {
                        result.error("BAD_URL", "No stream URL", null)
                        return
                    }
                    val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                    val id = nextId++
                    val inst = Instance(id, url, headers)
                    players[id] = inst
                    result.success(mapOf("id" to id, "textureId" to inst.textureId))
                }
                "play" -> { find(call)?.player?.playWhenReady = true; result.success(null) }
                "pause" -> { find(call)?.player?.playWhenReady = false; result.success(null) }
                "setVolume" -> {
                    val v = (call.argument<Double>("volume") ?: 1.0).toFloat().coerceIn(0f, 1f)
                    find(call)?.player?.volume = v
                    result.success(null)
                }
                "setAudioFocus" -> {
                    val inst = find(call)
                    val on = call.argument<Boolean>("enabled") ?: true
                    if (inst != null) inst.player.setAudioAttributes(inst.audioAttrs, on)
                    result.success(null)
                }
                "dispose" -> {
                    call.argument<Int>("id")?.let { players.remove(it)?.release() }
                    onStateChanged?.invoke()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("EXO_ERROR", e.message ?: e.toString(), null)
        }
    }

    private fun find(call: MethodCall): Instance? =
        call.argument<Int>("id")?.let { players[it] }

    fun releaseAll() {
        players.values.toList().forEach { it.release() }
        players.clear()
        onStateChanged?.invoke()
    }

    /** Releases everything and stops the guard timer (activity / engine teardown). */
    fun destroy() {
        onStateChanged = null
        onVideoAspect = null
        releaseAll()
        main.removeCallbacks(guardTicker)
    }

    private fun emit(id: Int, data: Map<String, Any?>) {
        val m = HashMap<String, Any?>(data)
        m["id"] = id
        main.post { channel.invokeMethod("event", m) }
    }

    private inner class Instance(
        private val id: Int,
        url: String,
        headers: Map<String, String>
    ) {
        private val producer: TextureRegistry.SurfaceProducer = textures.createSurfaceProducer()
        val textureId: Long = producer.id()
        val player: ExoPlayer
        val audioAttrs: AudioAttributes = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
            .build()
        private var released = false
        private var hasVideo = true
        private var startedUrl: String = url
        private var forcedHls = false
        fun isWanted(): Boolean = !released && player.playWhenReady
        private val posTicker = object : Runnable {
            override fun run() {
                if (released) return
                emit(id, mapOf("type" to "pos", "ms" to player.currentPosition))
                main.postDelayed(this, 500)
            }
        }

        init {
            // --- HTTP: accept redirects http<->https, keep-alive, 15 s timeouts.
            val ua = headers.entries.firstOrNull { it.key.equals("User-Agent", true) }?.value
            val http = DefaultHttpDataSource.Factory()
                .setAllowCrossProtocolRedirects(true)
                .setConnectTimeoutMs(15000)
                .setReadTimeoutMs(15000)
                .setDefaultRequestProperties(headers.filterKeys { !it.equals("User-Agent", true) })
            if (!ua.isNullOrEmpty()) http.setUserAgent(ua)

            // --- Tolerant MPEG-TS (live IPTV streams are often not clean).
            val extractors = DefaultExtractorsFactory()
                .setTsExtractorFlags(
                    DefaultTsPayloadReaderFactory.FLAG_ALLOW_NON_IDR_KEYFRAMES or
                        DefaultTsPayloadReaderFactory.FLAG_DETECT_ACCESS_UNITS
                )
                .setConstantBitrateSeekingEnabled(true)

            // --- Endless-ish retries on network errors (live TV must reconnect).
            val retry = DefaultLoadErrorHandlingPolicy(10)

            val sourceFactory = DefaultMediaSourceFactory(context, extractors)
                .setDataSourceFactory(http)
                .setLoadErrorHandlingPolicy(retry)

            // --- Decoders: hardware first, software fallback, FFmpeg audio
            // (class is picked up by reflection when the FFmpeg module is bundled).
            val renderers = DefaultRenderersFactory(context)
                .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)
                .setEnableDecoderFallback(true)

            // --- Buffer like a TV box: 15-50 s ahead, start after 2.5 s.
            val load = DefaultLoadControl.Builder()
                .setBufferDurationsMs(15_000, 50_000, 2_500, 5_000)
                .setTargetBufferBytes(C.LENGTH_UNSET)
                .setPrioritizeTimeOverSizeThresholds(true)
                .build()

            player = ExoPlayer.Builder(context, renderers)
                .setMediaSourceFactory(sourceFactory)
                .setLoadControl(load)
                // Audio focus is NOT taken at creation. A channel that is still
                // warming up must not steal focus from the one being watched
                // (that made the old channel pause during a switch). Dart calls
                // setAudioFocus(true) once this player is the visible channel.
                .setAudioAttributes(audioAttrs, false)
                .setHandleAudioBecomingNoisy(true)
                .build()

            producer.setSize(1920, 1080)
            producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceAvailable() {
                    if (!released) player.setVideoSurface(producer.getSurface())
                }

                override fun onSurfaceCleanup() {
                    if (!released) player.clearVideoSurface()
                }
            })
            player.setVideoSurface(producer.getSurface())

            // Diagnostics shown on screen (which decoder opened, codec errors).
            player.addAnalyticsListener(object : AnalyticsListener {
                override fun onVideoDecoderInitialized(
                    eventTime: AnalyticsListener.EventTime,
                    decoderName: String,
                    initializedTimestampMs: Long,
                    initializationDurationMs: Long
                ) {
                    emit(id, mapOf("type" to "info", "message" to "Video decoder: $decoderName"))
                }

                override fun onVideoInputFormatChanged(
                    eventTime: AnalyticsListener.EventTime,
                    format: Format,
                    decoderReuseEvaluation: androidx.media3.exoplayer.DecoderReuseEvaluation?
                ) {
                    emit(id, mapOf("type" to "info", "message" to
                        "Video: ${format.sampleMimeType} ${format.width}x${format.height} ${if (format.frameRate > 0) format.frameRate.toInt().toString() + "fps" else ""}"))
                }

                override fun onVideoCodecError(eventTime: AnalyticsListener.EventTime, videoCodecError: Exception) {
                    emit(id, mapOf("type" to "info", "message" to "Video codec error: ${videoCodecError.message}"))
                }

                override fun onAudioCodecError(eventTime: AnalyticsListener.EventTime, audioCodecError: Exception) {
                    emit(id, mapOf("type" to "info", "message" to "Audio codec error: ${audioCodecError.message}"))
                }
            })

            player.addListener(object : Player.Listener {
                override fun onVideoSizeChanged(size: VideoSize) {
                    var w = size.width
                    var h = size.height
                    if (size.unappliedRotationDegrees == 90 || size.unappliedRotationDegrees == 270) {
                        val t = w; w = h; h = t
                    }
                    if (w > 0 && h > 0) {
                        producer.setSize(w, h)
                        player.setVideoSurface(producer.getSurface())
                    }
                    if (w > 0 && h > 0) {
                        val par = if (size.pixelWidthHeightRatio > 0f) size.pixelWidthHeightRatio.toDouble() else 1.0
                        onVideoAspect?.invoke(w * par / h)
                    }
                    emit(id, mapOf(
                        "type" to "size", "width" to w, "height" to h,
                        "par" to (if (size.pixelWidthHeightRatio > 0f) size.pixelWidthHeightRatio.toDouble() else 1.0)
                    ))
                }

                override fun onTracksChanged(tracks: Tracks) {
                    hasVideo = tracks.isTypeSelected(C.TRACK_TYPE_VIDEO)
                    sendState()
                }

                override fun onPlaybackStateChanged(state: Int) = sendState()
                override fun onIsPlayingChanged(isPlaying: Boolean) = sendState()
                override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) = sendState()

                override fun onPlayerError(error: PlaybackException) {
                    // Live window fell behind: rejoin the live edge and carry on.
                    if (error.errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW) {
                        player.seekToDefaultPosition()
                        player.prepare()
                        return
                    }
                    // Extension-less link that was not recognised: retry once as HLS.
                    if (!forcedHls && (error.errorCode == PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED ||
                            error.errorCode == PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED)) {
                        forcedHls = true
                        player.setMediaItem(buildItem(AnantaUrlResolver.Result(startedUrl, MimeTypes.APPLICATION_M3U8)))
                        player.prepare()
                        return
                    }
                    emit(id, mapOf("type" to "error", "message" to "${error.errorCodeName}: ${error.message ?: ""}"))
                }
            })

            player.playWhenReady = false
            main.postDelayed(posTicker, 500)

            // Short links (jmp2.uk, shorturl.at, tinyurl ...) are resolved off the
            // main thread first; direct .m3u8/.ts/.mpd links start immediately.
            if (AnantaUrlResolver.looksDirect(url)) {
                startMedia(AnantaUrlResolver.Result(url, null))
            } else {
                Thread {
                    val r = try {
                        AnantaUrlResolver.resolve(url, headers)
                    } catch (e: Exception) {
                        AnantaUrlResolver.Result(url, null)
                    }
                    main.post { if (!released) startMedia(r) }
                }.start()
            }
        }

        private fun buildItem(r: AnantaUrlResolver.Result): MediaItem {
            val b = MediaItem.Builder()
                .setUri(r.url)
                .setLiveConfiguration(
                    MediaItem.LiveConfiguration.Builder()
                        .setTargetOffsetMs(8_000)
                        .setMinOffsetMs(4_000)
                        .setMaxOffsetMs(30_000)
                        .setMinPlaybackSpeed(1.0f)
                        .setMaxPlaybackSpeed(1.0f)
                        .build()
                )
            if (r.mimeType != null) b.setMimeType(r.mimeType)
            return b.build()
        }

        private fun startMedia(r: AnantaUrlResolver.Result) {
            if (released) return
            startedUrl = r.url
            player.setMediaItem(buildItem(r))
            player.prepare()
        }

        private fun sendState() {
            if (released) return
            onStateChanged?.invoke()
            val st = player.playbackState
            emit(id, mapOf(
                "type" to "state",
                "buffering" to (st == Player.STATE_BUFFERING && player.playWhenReady),
                "playing" to player.isPlaying,
                "playWhenReady" to player.playWhenReady,
                "ended" to (st == Player.STATE_ENDED),
                "ready" to (st == Player.STATE_READY),
                "hasVideo" to hasVideo
            ))
        }

        fun release() {
            if (released) return
            released = true
            main.removeCallbacks(posTicker)
            try { player.stop() } catch (_: Exception) {}
            try { player.clearVideoSurface() } catch (_: Exception) {}
            try { player.release() } catch (_: Exception) {}
            try { producer.release() } catch (_: Exception) {}
        }
    }
}
