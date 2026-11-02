package com.ananta.ott

import android.content.Context
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
import java.net.Socket
import java.security.KeyStore
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509ExtendedTrustManager

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

    init {
        LenientTls.install()
        channel.setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "create" -> {
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
        private val srcUrl: String = url
        private val srcHeaders: Map<String, String> = headers
        private var tickerStarted = false
        private var lastUrl: String = ""
        private var lastMime: String? = null
        private var triedHlsFallback = false
        private var triedTsFallback = false
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
                    // The stream type could not be guessed (short / extension-less
                    // link, odd content-type). Retry once as HLS, then once as DASH.
                    val formatError = error.errorCode == PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED ||
                        error.errorCode == PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED ||
                        error.errorCode == PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED ||
                        error.errorCode == PlaybackException.ERROR_CODE_PARSING_MANIFEST_MALFORMED
                    if (formatError && lastMime == null && !triedHlsFallback && lastUrl.isNotEmpty()) {
                        triedHlsFallback = true
                        startPlayback(lastUrl, MimeTypes.APPLICATION_M3U8)
                        return
                    }
                    // Resolved as HLS but it is really a raw MPEG-TS stream: retry as TS.
                    if (formatError && lastMime == MimeTypes.APPLICATION_M3U8 && !triedTsFallback && lastUrl.isNotEmpty()) {
                        triedTsFallback = true
                        startPlayback(lastUrl, MimeTypes.VIDEO_MP2T)
                        return
                    }
                    // Live window fell behind: rejoin the live edge and carry on.
                    if (error.errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW) {
                        player.seekToDefaultPosition()
                        player.prepare()
                        return
                    }
                    emit(id, mapOf("type" to "error", "message" to "${error.errorCodeName}: ${error.message ?: ""}"))
                }
            })

            // Short / redirect links (tinyurl, bit.ly ...) have no file extension, so
            // ExoPlayer cannot tell HLS from TS. Resolve the redirect chain first,
            // then play the final URL with the right media type.
            if (needsResolve(srcUrl)) {
                Thread {
                    val resolved = try { resolveRedirects(srcUrl) } catch (e: Exception) { Pair(srcUrl, null as String?) }
                    main.post { if (!released) startPlayback(resolved.first, resolved.second) }
                }.start()
            } else {
                startPlayback(srcUrl, null)
            }
        }

        private fun startPlayback(finalUrl: String, mime: String?) {
            lastUrl = finalUrl
            lastMime = mime
            val builder = MediaItem.Builder()
                .setUri(finalUrl)
                .setLiveConfiguration(
                    MediaItem.LiveConfiguration.Builder()
                        .setTargetOffsetMs(8_000)
                        .setMinOffsetMs(4_000)
                        .setMaxOffsetMs(30_000)
                        .setMinPlaybackSpeed(1.0f)
                        .setMaxPlaybackSpeed(1.0f)
                        .build()
                )
            if (mime != null) builder.setMimeType(mime)
            player.setMediaItem(builder.build())
            player.prepare()
            if (!tickerStarted) {
                tickerStarted = true
                main.postDelayed(posTicker, 500)
            }
        }

        private fun needsResolve(u: String): Boolean {
            val path = try { java.net.URI(u).path ?: "" } catch (e: Exception) { u }
            return !Regex("\\.(m3u8?|mpd|ts|mp4|mkv|flv|aac|mp3|avi|mov|webm)$", RegexOption.IGNORE_CASE).containsMatchIn(path)
        }

        /**
         * Follows a short / redirect link by hand and works out what it really is:
         *  - HTTP 30x redirects (any number of hops, http<->https),
         *  - a 4xx answer to the player User-Agent is retried once as a browser,
         *  - a plain-text body that is just a URL,
         *  - an IPTV .m3u list (#EXTINF, no HLS tags): the first stream URL is used,
         *  - an HTML page with a meta-refresh / location redirect,
         *  - HLS / DASH detected from the content-type or the first bytes.
         */
        private fun resolveRedirects(start: String): Pair<String, String?> {
            val browserUa = "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36"
            val htmlRedirect = Regex("""(?i)(?:http-equiv=["']refresh["'][^>]*?content=["'][^"']*?url=|location(?:\.href)?\s*=\s*["']|location\.replace\(["'])([^"'>\s]+)""")
            var current = start
            var asBrowser = false
            var hops = 0
            while (hops < 12) {
                hops++
                val conn = java.net.URL(current).openConnection() as java.net.HttpURLConnection
                try {
                    conn.instanceFollowRedirects = false
                    conn.connectTimeout = 10000
                    conn.readTimeout = 10000
                    srcHeaders.forEach { (k, v) -> conn.setRequestProperty(k, v) }
                    if (asBrowser) conn.setRequestProperty("User-Agent", browserUa)
                    val code = conn.responseCode
                    if (code in 300..399) {
                        val loc = conn.getHeaderField("Location") ?: return Pair(current, null)
                        current = java.net.URL(java.net.URL(current), loc).toString()
                        continue
                    }
                    if (code >= 400) {
                        if (!asBrowser) {
                            asBrowser = true
                            hops--
                            continue
                        }
                        return Pair(current, null)
                    }
                    val ct = (conn.contentType ?: "").lowercase()
                    if (ct.contains("mpegurl")) return Pair(current, MimeTypes.APPLICATION_M3U8)
                    if (ct.contains("dash+xml")) return Pair(current, MimeTypes.APPLICATION_MPD)
                    if (ct.startsWith("video/") || ct.startsWith("audio/")) return Pair(current, null)
                    // Unknown / text / octet-stream: look at the first bytes.
                    val buf = ByteArray(8192)
                    var total = 0
                    val input = conn.inputStream
                    while (total < buf.size) {
                        val n = input.read(buf, total, buf.size - total)
                        if (n <= 0) break
                        total += n
                    }
                    val text = String(buf, 0, total, Charsets.ISO_8859_1)
                    val trimmed = text.trimStart()
                    if (trimmed.startsWith("#EXTM3U")) {
                        if (!trimmed.contains("#EXT-X-")) {
                            // IPTV channel list, not an HLS playlist: use its first stream.
                            val first = trimmed.lineSequence().map { it.trim() }
                                .firstOrNull { it.startsWith("http://") || it.startsWith("https://") }
                            if (first != null) {
                                current = first
                                continue
                            }
                        }
                        return Pair(current, MimeTypes.APPLICATION_M3U8)
                    }
                    if (trimmed.startsWith("http://") || trimmed.startsWith("https://")) {
                        current = trimmed.lineSequence().first().trim()
                        continue
                    }
                    if (ct.contains("html")) {
                        val m = htmlRedirect.find(text)
                        if (m != null) {
                            current = java.net.URL(java.net.URL(current), m.groupValues[1]).toString()
                            continue
                        }
                    }
                    return Pair(current, null)
                } finally {
                    try { conn.disconnect() } catch (_: Exception) {}
                }
            }
            return Pair(current, null)
        }

        private fun sendState() {
            if (released) return
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


/**
 * Some IPTV CDNs forget to renew their TLS certificate, which makes Android
 * refuse the connection even though the stream itself is fine (browsers let
 * the user "proceed anyway"). For the hosts listed in [LENIENT_SUFFIXES] only,
 * an *expired* (or otherwise failing) certificate is accepted. Every other host
 * keeps the normal, strict system certificate check.
 */
object LenientTls {
    /** Host suffixes whose certificate problems are tolerated. */
    private val LENIENT_SUFFIXES = listOf("medialive.one")

    @Volatile private var installed = false

    private fun isLenient(host: String?): Boolean {
        val h = host?.lowercase() ?: return false
        return LENIENT_SUFFIXES.any { h == it || h.endsWith(".$it") }
    }

    fun install() {
        if (installed) return
        try {
            val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
            factory.init(null as KeyStore?)
            val system = factory.trustManagers.filterIsInstance<X509ExtendedTrustManager>().firstOrNull()
                ?: return // cannot wrap: keep the default (strict) behaviour
            val tm = object : X509ExtendedTrustManager() {
                override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) =
                    system.checkClientTrusted(chain, authType)
                override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String, socket: Socket?) =
                    system.checkClientTrusted(chain, authType, socket)
                override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String, engine: SSLEngine?) =
                    system.checkClientTrusted(chain, authType, engine)
                override fun getAcceptedIssuers(): Array<X509Certificate> = system.acceptedIssuers

                override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) =
                    system.checkServerTrusted(chain, authType)

                override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String, socket: Socket?) {
                    try {
                        system.checkServerTrusted(chain, authType, socket)
                    } catch (e: CertificateException) {
                        val host = (socket as? SSLSocket)?.handshakeSession?.peerHost
                            ?: socket?.inetAddress?.hostName
                        if (!isLenient(host)) throw e
                        android.util.Log.w("AnantaTLS", "Accepting invalid certificate for $host: ${e.message}")
                    }
                }

                override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String, engine: SSLEngine?) {
                    try {
                        system.checkServerTrusted(chain, authType, engine)
                    } catch (e: CertificateException) {
                        val host = engine?.handshakeSession?.peerHost ?: engine?.peerHost
                        if (!isLenient(host)) throw e
                        android.util.Log.w("AnantaTLS", "Accepting invalid certificate for $host: ${e.message}")
                    }
                }
            }
            val ctx = SSLContext.getInstance("TLS")
            ctx.init(null, arrayOf(tm), null)
            HttpsURLConnection.setDefaultSSLSocketFactory(ctx.socketFactory)
            installed = true
        } catch (e: Exception) {
            android.util.Log.w("AnantaTLS", "Lenient TLS not installed: ${e.message}")
        }
    }
}
