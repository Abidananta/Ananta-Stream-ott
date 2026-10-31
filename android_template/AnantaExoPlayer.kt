package com.ananta.ott

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.Surface
import androidx.media3.common.AudioAttributes
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
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

            // --- Never reject a stream because it is big: 2560x1440 @ 50 fps H.264
            // (like the VLC info) can exceed a decoder's advertised level, but the
            // hardware usually still plays it. Keep every track selectable.
            val trackSelector = DefaultTrackSelector(context).apply {
                setParameters(
                    buildUponParameters()
                        .setExceedVideoConstraintsIfNecessary(true)
                        .setExceedRendererCapabilitiesIfNecessary(true)
                        .setMaxVideoSize(Int.MAX_VALUE, Int.MAX_VALUE)
                        .setMaxVideoFrameRate(Int.MAX_VALUE)
                        .setMaxVideoBitrate(Int.MAX_VALUE)
                        .setForceHighestSupportedBitrate(true)
                )
            }

            player = ExoPlayer.Builder(context, renderers)
                .setTrackSelector(trackSelector)
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
            val st = player.playbackState
            emit(id, mapOf(
                "type" to "state",
                "buffering" to (st == Player.STATE_BUFFERING && player.playWhenReady),
                "playing" to player.isPlaying,
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
