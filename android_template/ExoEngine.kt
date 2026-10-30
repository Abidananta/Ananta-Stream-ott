package com.ananta.ott

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.decoder.ffmpeg.FfmpegAudioRenderer
import androidx.media3.decoder.ffmpeg.FfmpegLibrary
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.audio.AudioRendererEventListener
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.dash.DashMediaSource
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.rtsp.RtspMediaSource
import androidx.media3.exoplayer.smoothstreaming.SsMediaSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * Native AndroidX Media3 ExoPlayer engine - the same engine family TiviMate's
 * built-in player uses - exposed to Dart through a MethodChannel and rendered
 * into a Flutter Texture, so the existing Flutter UI is untouched.
 *
 * Stream support:
 *  - HLS, DASH, SmoothStreaming, RTSP, progressive/raw MPEG-TS, MP4, MKV, FLV, AAC, MP3...
 *  - URLs without an extension are probed: progressive -> HLS -> DASH.
 *  - FFmpeg software audio decoder is used whenever the device has no hardware
 *    decoder (MP2/MPGA, AC3, E-AC3, DTS, Vorbis, Opus, ALAC, ...).
 */
@UnstableApi
class ExoEngine(
    private val context: Context,
    messenger: BinaryMessenger,
    private val textures: TextureRegistry,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "com.ananta.ott/exo")
    private val main = Handler(Looper.getMainLooper())
    private val sessions = HashMap<Int, Session>()
    private var nextId = 1

    init {
        channel.setMethodCallHandler(this)
    }

    fun release() {
        channel.setMethodCallHandler(null)
        sessions.values.toList().forEach { it.release() }
        sessions.clear()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "create" -> {
                    val url = call.argument<String>("url") ?: return result.error("ARG", "url missing", null)
                    val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                    val id = nextId++
                    val s = Session(id, url, headers)
                    sessions[id] = s
                    result.success(mapOf("id" to id, "textureId" to s.textureId()))
                }
                "play" -> { session(call)?.player?.play(); result.success(true) }
                "pause" -> { session(call)?.player?.pause(); result.success(true) }
                "stop" -> { session(call)?.player?.stop(); result.success(true) }
                "setVolume" -> {
                    session(call)?.player?.volume = (call.argument<Double>("volume") ?: 1.0).toFloat()
                    result.success(true)
                }
                "dispose" -> {
                    val id = call.argument<Int>("id")
                    sessions.remove(id)?.release()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            result.error("EXO", t.message ?: t.toString(), null)
        }
    }

    private fun session(call: MethodCall): Session? = sessions[call.argument<Int>("id")]

    private fun emit(id: Int, type: String, extra: Map<String, Any?> = emptyMap()) {
        val m = HashMap<String, Any?>(extra)
        m["id"] = id
        m["type"] = type
        channel.invokeMethod("event", m)
    }

    /** Software (FFmpeg) audio decoder is appended as a fallback after MediaCodec. */
    private class AnantaRenderersFactory(ctx: Context) : DefaultRenderersFactory(ctx) {
        init {
            setExtensionRendererMode(EXTENSION_RENDERER_MODE_OFF)
            setEnableDecoderFallback(true)
        }

        override fun buildAudioRenderers(
            context: Context,
            extensionRendererMode: Int,
            mediaCodecSelector: MediaCodecSelector,
            enableDecoderFallback: Boolean,
            audioSink: AudioSink,
            eventHandler: Handler,
            eventListener: AudioRendererEventListener,
            out: ArrayList<Renderer>,
        ) {
            super.buildAudioRenderers(
                context, extensionRendererMode, mediaCodecSelector,
                enableDecoderFallback, audioSink, eventHandler, eventListener, out,
            )
            try {
                if (FfmpegLibrary.isAvailable()) {
                    out.add(FfmpegAudioRenderer(eventHandler, eventListener, audioSink))
                }
            } catch (_: Throwable) {
                // Native FFmpeg library missing: hardware decoders only.
            }
        }
    }

    private enum class Kind { PROGRESSIVE, HLS, DASH, SS, RTSP }

    private inner class Session(val id: Int, val url: String, headers: Map<String, String>) {
        private val producer: TextureRegistry.SurfaceProducer = textures.createSurfaceProducer()
        val player: ExoPlayer
        private val httpFactory: DefaultHttpDataSource.Factory
        private val dataFactory: DefaultDataSource.Factory
        private val order: List<Kind>
        private var attempt = 0
        private var released = false
        private var hasVideo = false
        private var firstFrameSent = false
        private val ticker = object : Runnable {
            override fun run() {
                if (released) return
                emit(id, "position", mapOf("ms" to player.currentPosition))
                main.postDelayed(this, 1000)
            }
        }

        private val listener = object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                emit(id, "buffering", mapOf("value" to (state == Player.STATE_BUFFERING)))
                if (state == Player.STATE_ENDED) emit(id, "ended")
                if (state == Player.STATE_READY && !hasVideo && !firstFrameSent) {
                    // Radio / audio-only stream: nothing to wait for.
                    main.postDelayed({
                        if (!released && !hasVideo && !firstFrameSent) emit(id, "audioOnly")
                    }, 1500)
                }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                emit(id, "playing", mapOf("value" to isPlaying))
            }

            override fun onTracksChanged(tracks: Tracks) {
                hasVideo = tracks.isTypeSelected(C.TRACK_TYPE_VIDEO)
            }

            override fun onVideoSizeChanged(size: VideoSize) {
                if (size.width <= 0 || size.height <= 0) return
                val w = (size.width * size.pixelWidthHeightRatio).toInt().coerceAtLeast(1)
                val h = size.height
                producer.setSize(size.width, size.height)
                emit(id, "size", mapOf("w" to w, "h" to h))
            }

            override fun onRenderedFirstFrame() {
                firstFrameSent = true
                emit(id, "firstFrame")
            }

            override fun onPlayerError(error: PlaybackException) {
                when (error.errorCode) {
                    PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW -> {
                        player.seekToDefaultPosition()
                        player.prepare()
                        return
                    }
                    PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
                    PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED,
                    PlaybackException.ERROR_CODE_PARSING_MANIFEST_MALFORMED,
                    PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED -> {
                        // Wrong guess about the stream type: try the next engine path.
                        if (attempt + 1 < order.size) {
                            attempt++
                            load()
                            return
                        }
                    }
                }
                emit(id, "error", mapOf("message" to "${error.errorCodeName}: ${error.message}"))
            }
        }

        fun textureId(): Long = producer.id()

        init {
            val h = HashMap(headers)
            val uaKey = h.keys.firstOrNull { it.equals("User-Agent", ignoreCase = true) }
            val ua = if (uaKey != null) h.remove(uaKey) else null
            httpFactory = DefaultHttpDataSource.Factory()
                .setAllowCrossProtocolRedirects(true)
                .setConnectTimeoutMs(15000)
                .setReadTimeoutMs(20000)
                .setUserAgent(ua ?: "TiviMate/5.0.0 (Android)")
                .setDefaultRequestProperties(h)
            dataFactory = DefaultDataSource.Factory(context, httpFactory)

            val loadControl = DefaultLoadControl.Builder()
                .setBufferDurationsMs(15000, 60000, 2500, 5000)
                .setTargetBufferBytes(48 * 1024 * 1024)
                .setPrioritizeTimeOverSizeThresholds(false)
                .build()

            player = ExoPlayer.Builder(context, AnantaRenderersFactory(context))
                .setLoadControl(loadControl)
                .setTrackSelector(DefaultTrackSelector(context))
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(C.USAGE_MEDIA)
                        .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                        .build(),
                    true,
                )
                .build()

            producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceAvailable() {
                    if (!released) player.setVideoSurface(producer.surface)
                }

                override fun onSurfaceCleanup() {
                    if (!released) player.clearVideoSurface()
                }
            })
            player.setVideoSurface(producer.surface)
            player.addListener(listener)

            order = guessOrder(Uri.parse(url))
            load()
            main.postDelayed(ticker, 1000)
        }

        private fun guessOrder(uri: Uri): List<Kind> {
            val scheme = uri.scheme?.lowercase() ?: ""
            val full = url.lowercase()
            val path = (uri.path ?: "").lowercase()
            return when {
                scheme == "rtsp" || scheme == "rtsps" -> listOf(Kind.RTSP)
                path.endsWith(".m3u8") || full.contains(".m3u8") -> listOf(Kind.HLS, Kind.PROGRESSIVE, Kind.DASH)
                path.endsWith(".mpd") || full.contains(".mpd") -> listOf(Kind.DASH, Kind.HLS, Kind.PROGRESSIVE)
                path.endsWith(".ism") || path.contains(".ism/") -> listOf(Kind.SS, Kind.HLS, Kind.PROGRESSIVE)
                else -> listOf(Kind.PROGRESSIVE, Kind.HLS, Kind.DASH, Kind.SS)
            }
        }

        private fun buildSource(kind: Kind): MediaSource {
            val item = MediaItem.fromUri(url)
            val policy = DefaultLoadErrorHandlingPolicy(8)
            return when (kind) {
                Kind.HLS -> HlsMediaSource.Factory(dataFactory)
                    .setAllowChunklessPreparation(true)
                    .setLoadErrorHandlingPolicy(policy)
                    .createMediaSource(item)
                Kind.DASH -> DashMediaSource.Factory(dataFactory)
                    .setLoadErrorHandlingPolicy(policy)
                    .createMediaSource(item)
                Kind.SS -> SsMediaSource.Factory(dataFactory)
                    .setLoadErrorHandlingPolicy(policy)
                    .createMediaSource(item)
                Kind.RTSP -> RtspMediaSource.Factory()
                    .setForceUseRtpTcp(true)
                    .createMediaSource(item)
                Kind.PROGRESSIVE -> {
                    val extractors = DefaultExtractorsFactory()
                        .setTsExtractorFlags(
                            DefaultTsPayloadReaderFactory.FLAG_ALLOW_NON_IDR_KEYFRAMES or
                                DefaultTsPayloadReaderFactory.FLAG_DETECT_ACCESS_UNITS,
                        )
                        .setConstantBitrateSeekingEnabled(true)
                    ProgressiveMediaSource.Factory(dataFactory, extractors)
                        .setLoadErrorHandlingPolicy(policy)
                        .createMediaSource(item)
                }
            }
        }

        private fun load() {
            player.setMediaSource(buildSource(order[attempt]))
            player.prepare()
        }

        fun release() {
            if (released) return
            released = true
            main.removeCallbacks(ticker)
            try { player.stop() } catch (_: Throwable) {}
            try { player.release() } catch (_: Throwable) {}
            try { producer.release() } catch (_: Throwable) {}
        }
    }
}
