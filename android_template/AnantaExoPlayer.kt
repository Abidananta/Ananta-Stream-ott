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
                    emit(id, mapOf("type" to "error", "message" to "${error.errorCodeName}: ${error.message ?: ""}"))
                }
            })

            val item = MediaItem.Builder()
                .setUri(url)
                .setLiveConfiguration(
                    MediaItem.LiveConfiguration.Builder()
                        .setTargetOffsetMs(8_000)
                        .setMinOffsetMs(4_000)
                        .setMaxOffsetMs(30_000)
                        .setMinPlaybackSpeed(1.0f)
                        .setMaxPlaybackSpeed(1.0f)
                        .build()
                )
                .build()
            player.setMediaItem(item)
            player.playWhenReady = false
            player.prepare()
            main.postDelayed(posTicker, 500)
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
