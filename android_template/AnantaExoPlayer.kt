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
import androidx.media3.exoplayer.trackselection.AdaptiveTrackSelection
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.exoplayer.upstream.DefaultBandwidthMeter
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
                    if (SniffGuard.isCaptured(context)) {
                        result.error("SNIFFER", SniffGuard.MESSAGE, null)
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
        // Quality safety net: after a stall the top quality is capped for a while.
        private var abrSelector: DefaultTrackSelector? = null
        private var abrCapReleaseAt = 0L
        private var prevPlayerState = Player.STATE_IDLE
        // Last picture size given to the texture (kept while only the quality changes).
        private var surfaceW = 0
        private var surfaceH = 0
        private var lastUrl: String = ""
        private var lastMime: String? = null
        private var triedHlsFallback = false
        private var triedTsFallback = false
        private val posTicker = object : Runnable {
            private var guardTick = 0
            override fun run() {
                if (released) return
                // Every ~3 s: if a capture tool was started during playback, stop.
                if (++guardTick % 6 == 0 && SniffGuard.isCaptured(context)) {
                    try { player.stop(); player.clearMediaItems() } catch (_: Exception) {}
                    emit(id, mapOf("type" to "error", "message" to SniffGuard.MESSAGE))
                    return
                }
                if (abrCapReleaseAt != 0L && System.currentTimeMillis() > abrCapReleaseAt) {
                    abrCapReleaseAt = 0L
                    abrSelector?.let { it.setParameters(it.buildUponParameters().setMaxVideoBitrate(Int.MAX_VALUE)) }
                }
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

            // --- Buffer like a TV box: 30-60 s ahead (a long cushion rides out
            // short speed dips), start after 3 s, and after a stall refill 10 s
            // first so it does not stutter again right away.
            val load = DefaultLoadControl.Builder()
                .setBufferDurationsMs(30_000, 60_000, 3_000, 10_000)
                .setTargetBufferBytes(C.LENGTH_UNSET)
                .setPrioritizeTimeOverSizeThresholds(true)
                .build()

            // --- Quality follows the real connection speed automatically:
            //  * a quality is only chosen if it needs 70% of the measured speed
            //    (30% safety margin, so a normal dip does not cause buffering);
            //  * it steps DOWN early (buffer under 25 s - live streams only ever
            //    hold ~10-20 s, so this means "right away") and the buffered
            //    video is kept, so there is no gap;
            //  * it steps UP as soon as the buffer is healthy (10 s) and the
            //    speed really allows the better quality;
            //  * it never switches to a variant that needs a decoder restart
            //    (that restart is the visible hiccup);
            //  * if the picture still stalls once, the top quality is capped to
            //    60% of the measured speed for 90 s, then released again.
            val bandwidth = DefaultBandwidthMeter.Builder(context)
                .setInitialBitrateEstimate(3_000_000L)
                .setResetOnNetworkTypeChange(false)
                .setSlidingWindowMaxWeight(3000)
                .build()
            val trackFactory = AdaptiveTrackSelection.Factory(
                10_000,    // minDurationForQualityIncreaseMs
                25_000,    // maxDurationForQualityDecreaseMs
                60_000,    // minDurationToRetainAfterDiscardMs (keep what is buffered)
                0.70f      // bandwidthFraction
            )
            val trackSelector = DefaultTrackSelector(context, trackFactory)
            abrSelector = trackSelector
            trackSelector.setParameters(
                trackSelector.buildUponParameters()
                    .setAllowVideoNonSeamlessAdaptiveness(false)
                    .setAllowVideoMixedMimeTypeAdaptiveness(false)
                    .setMaxVideoSize(1920, 1080)
            )

            player = ExoPlayer.Builder(context, renderers)
                .setMediaSourceFactory(sourceFactory)
                .setLoadControl(load)
                .setBandwidthMeter(bandwidth)
                .setTrackSelector(trackSelector)
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
                        // A quality switch changes the resolution but not the shape of
                        // the picture. Re-creating the texture for it causes a visible
                        // flicker, so only do it when the aspect ratio really changes.
                        val sameShape = surfaceW > 0 && surfaceH > 0 &&
                            Math.abs(w.toFloat() / h - surfaceW.toFloat() / surfaceH) < 0.02f
                        if (!sameShape) {
                            surfaceW = w; surfaceH = h
                            producer.setSize(w, h)
                            player.setVideoSurface(producer.getSurface())
                        }
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

                override fun onPlaybackStateChanged(state: Int) {
                    if (state == Player.STATE_BUFFERING && prevPlayerState == Player.STATE_READY && player.playWhenReady) {
                        // Picture stalled: the current quality is too heavy for the
                        // connection right now, so hold it lower for a while.
                        try {
                            val cap = (bandwidth.bitrateEstimate * 6 / 10).coerceIn(400_000L, Int.MAX_VALUE.toLong()).toInt()
                            trackSelector.setParameters(trackSelector.buildUponParameters().setMaxVideoBitrate(cap))
                            abrCapReleaseAt = System.currentTimeMillis() + 90_000
                        } catch (_: Exception) {}
                    }
                    prevPlayerState = state
                    sendState()
                }
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
            if (SniffGuard.isCaptured(context)) {
                emit(id, mapOf("type" to "error", "message" to SniffGuard.MESSAGE))
                return
            }
            lastUrl = finalUrl
            lastMime = mime
            val builder = MediaItem.Builder()
                .setUri(finalUrl)
                .setLiveConfiguration(
                    MediaItem.LiveConfiguration.Builder()
                        .setTargetOffsetMs(15_000)
                        .setMinOffsetMs(10_000)
                        .setMaxOffsetMs(45_000)
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


/**
 * Anti-sniffing guard. Packet-capture tools such as HTTP Canary work by
 * starting a local VPN so that every request of the app - including the
 * .m3u8 links - passes through them. While such a VPN is up this guard binds
 * the whole app process to the real (non-VPN) network, so the playlist and all
 * streams keep working but their traffic never enters the capture tool.
 * A system-wide HTTP proxy cannot be bypassed that way, so with a proxy active
 * the app still refuses to load anything.
 */
object SniffGuard {
    private const val TAG = "AnantaGuard"
    // tun0, tap0, ppp0, wg0 ... (not tunl0 / ip6tnl0, which exist on many boxes)
    private val VPN_IFACE = Regex("^(tun|tap|ppp|pptp|wg)\\d+$")
    @Volatile private var callbackRegistered = false

    private fun cm(ctx: Context) =
        ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager

    /** Call once at start-up: keeps the bypass in step when a VPN comes and goes. */
    fun start(ctx: Context) {
        val app = ctx.applicationContext
        try {
            if (!callbackRegistered && android.os.Build.VERSION.SDK_INT >= 24) {
                val manager = cm(app)
                if (manager != null) {
                    manager.registerDefaultNetworkCallback(object : android.net.ConnectivityManager.NetworkCallback() {
                        override fun onAvailable(network: android.net.Network) { refresh(app) }
                        override fun onLost(network: android.net.Network) { refresh(app) }
                        override fun onCapabilitiesChanged(network: android.net.Network, caps: android.net.NetworkCapabilities) { refresh(app) }
                    })
                    callbackRegistered = true
                }
            }
        } catch (e: Throwable) {
            android.util.Log.w(TAG, "callback not registered: ${e.message}")
        }
        refresh(app)
    }

    /** True when the app's traffic can be seen by a capture tool. */
    fun isCaptured(ctx: Context): Boolean =
        try { proxyActive(ctx) || !refresh(ctx) } catch (e: Throwable) {
            android.util.Log.w(TAG, "check failed: ${e.message}")
            false
        }

    /**
     * Makes this process use the physical network when a VPN is up (and the
     * normal default when it is not). Returns true when the app's traffic is
     * NOT going through a VPN afterwards.
     */
    @Synchronized
    private fun refresh(ctx: Context): Boolean {
        val manager = cm(ctx) ?: return !vpnActive(ctx)
        if (android.os.Build.VERSION.SDK_INT < 23) return !vpnActive(ctx)
        if (!vpnActive(ctx)) {
            try { if (manager.boundNetworkForProcess != null) manager.bindProcessToNetwork(null) } catch (_: Throwable) {}
            return true
        }
        val physical = physicalNetwork(manager) ?: return false
        return try {
            manager.bindProcessToNetwork(physical) && manager.boundNetworkForProcess == physical
        } catch (e: Throwable) {
            android.util.Log.w(TAG, "bind failed: ${e.message}")
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun physicalNetwork(manager: android.net.ConnectivityManager): android.net.Network? {
        var fallback: android.net.Network? = null
        for (n in manager.allNetworks) {
            val c = manager.getNetworkCapabilities(n) ?: continue
            if (c.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)) continue
            if (!c.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
            if (c.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED)) return n
            if (fallback == null) fallback = n
        }
        return fallback
    }

    private fun vpnActive(ctx: Context): Boolean {
        // 1) Android's own view: any network that uses the VPN transport.
        try {
            val manager = cm(ctx)
            if (manager != null) {
                @Suppress("DEPRECATION")
                for (n in manager.allNetworks) {
                    val c = manager.getNetworkCapabilities(n)
                    if (c?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN) == true) return true
                }
            }
        } catch (_: Throwable) { /* permission missing etc: fall through */ }
        // 2) Fallback that needs no permission: a tun/ppp style interface is up.
        val ifaces = java.net.NetworkInterface.getNetworkInterfaces() ?: return false
        for (i in ifaces) {
            val name = i.name?.lowercase() ?: continue
            if (i.isUp && VPN_IFACE.matches(name)) return true
        }
        return false
    }

    private fun proxyActive(ctx: Context): Boolean {
        val host = System.getProperty("http.proxyHost") ?: System.getProperty("https.proxyHost")
        if (!host.isNullOrBlank()) return true
        @Suppress("DEPRECATION")
        val dh = android.net.Proxy.getDefaultHost()
        return !dh.isNullOrBlank()
    }

    const val MESSAGE = "Network monitoring tool detected. Turn it off to use Ananta OTT."
}
