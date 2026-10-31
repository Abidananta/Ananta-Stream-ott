package com.ananta.ott

import android.Manifest
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.widget.RemoteViews
import android.graphics.BitmapFactory
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import android.graphics.Color
import android.graphics.Rect
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import android.app.PictureInPictureParams
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.ananta.ott/pip"
    private var channel: MethodChannel? = null
    private var exo: AnantaExo? = null
    // True only while a stream is playing; gates Home/Recents auto-PiP.
    private var pipEnabled = false
    private var aspect = 16.0 / 9.0
    // Video area (screen pixels) used as PiP source rect for a smooth start.
    private var sourceRect: Rect? = null

    // Android TV / no-touchscreen boxes keep Flutter's default rendering (TV
    // mode is untouched). Phones and tablets render through a transparent
    // TextureView, so PiP resizing never exposes a white/solid surface.
    private val isTvDevice: Boolean by lazy {
        val ui = resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK
        ui == Configuration.UI_MODE_TYPE_TELEVISION ||
            !packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN)
    }

    override fun getRenderMode(): RenderMode =
        if (isTvDevice) super.getRenderMode() else RenderMode.texture

    override fun getTransparencyMode(): TransparencyMode =
        if (isTvDevice) super.getTransparencyMode() else TransparencyMode.transparent

    private fun makeWindowTransparent() {
        if (isTvDevice) return
        try {
            window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            window.decorView.setBackgroundColor(Color.TRANSPARENT)
        } catch (e: Exception) {
            // best effort
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Transparent behind Flutter: no white (or any solid) box can show while
        // the PiP window resizes / before the first video frame is drawn.
        window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        window.decorView.setBackgroundColor(Color.TRANSPARENT)
        setupNotices()
    }

    // Announcements: phones/tablets only (TV is untouched).
    private fun setupNotices() {
        if (isTvDevice) return
        try {
            AnantaNotice.ensureChannel(this)
            if (Build.VERSION.SDK_INT >= 33 &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7001)
            }
            // Firebase push: every phone listens to the "all" topic.
            try {
                FirebaseMessaging.getInstance().subscribeToTopic("all")
            } catch (e: Exception) {
                // Firebase not configured (google-services.json missing)
            }
            // Background check about every 15 minutes, even when the app is closed.
            val js = getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
            val already = Build.VERSION.SDK_INT >= 24 && js.getPendingJob(AnantaNotice.JOB_ID) != null
            if (!already) {
                val job = JobInfo.Builder(AnantaNotice.JOB_ID, ComponentName(this, NoticeJobService::class.java))
                    .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                    .setPeriodic(15 * 60 * 1000L)
                    .build()
                js.schedule(job)
            }
        } catch (e: Exception) {
            // best effort
        }
    }

    override fun onResume() {
        super.onResume()
        makeWindowTransparent()
        AnantaNotice.resumed = true
    }

    override fun onPause() {
        AnantaNotice.resumed = false
        super.onPause()
    }

    override fun onMultiWindowModeChanged(isInMultiWindowMode: Boolean, newConfig: Configuration) {
        super.onMultiWindowModeChanged(isInMultiWindowMode, newConfig)
        makeWindowTransparent()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupInstaller(flutterEngine)
        // ExoPlayer (Media3) playback engine, rendered into a Flutter texture.
        exo?.releaseAll()
        exo = AnantaExo(applicationContext, flutterEngine.dartExecutor.binaryMessenger, flutterEngine.renderer)
        val noticeChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.ananta.ott/notice")
        // Push received while the app is open: hand it to Flutter for the glass banner.
        AnantaNotice.listener = { n ->
            runOnUiThread {
                noticeChannel.invokeMethod("showNotice", mapOf("id" to n.id, "title" to n.title, "body" to n.body, "image" to n.image, "url" to n.url))
            }
        }
        noticeChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "checkNotice" -> {
                    if (isTvDevice) { result.success(null); return@setMethodCallHandler }
                    val inApp = AnantaNotice.resumed && !isPipActive()
                    Thread {
                        var out: Map<String, Any>? = null
                        try {
                            val n = AnantaNotice.fetch()
                            if (n != null && AnantaNotice.isNew(applicationContext, n)) {
                                AnantaNotice.markSeen(applicationContext, n)
                                if (inApp) {
                                    AnantaNotice.save(applicationContext, n)
                                    out = mapOf("id" to n.id, "title" to n.title, "body" to n.body, "image" to n.image, "url" to n.url)
                                } else {
                                    AnantaNotice.post(applicationContext, n)
                                }
                            }
                        } catch (e: Exception) {
                            // ignore, retried on next poll
                        }
                        runOnUiThread { result.success(out) }
                    }.start()
                }
                "getHistory" -> result.success(
                    if (isTvDevice) "[]" else AnantaNotice.history(applicationContext))
                "getLastRead" -> result.success(AnantaNotice.lastRead(applicationContext))
                "markRead" -> { AnantaNotice.markRead(applicationContext); result.success(true) }
                "clearHistory" -> { AnantaNotice.clearHistory(applicationContext); result.success(true) }
                else -> result.notImplemented()
            }
        }
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isPipSupported" -> result.success(isPipSupported())
                    "isPictureInPicture" -> result.success(isPipActive())
                    "enterPictureInPicture" -> {
                        call.argument<Double>("aspect")?.let { aspect = it }
                        result.success(enterPip())
                    }
                    "setPipSourceRect" -> {
                        val list = call.argument<List<Int>>("rect")
                        sourceRect = if (list != null && list.size == 4 && list[2] > list[0] && list[3] > list[1]) {
                            Rect(list[0], list[1], list[2], list[3])
                        } else null
                        updateAutoEnter()
                        result.success(true)
                    }
                    "setPipAutoEnter" -> {
                        pipEnabled = call.argument<Boolean>("enabled") ?: false
                        call.argument<Double>("aspect")?.let { aspect = it }
                        updateAutoEnter()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private val installAction: String get() = "$packageName.INSTALL_RESULT"
    private var installerChannel: MethodChannel? = null
    private var installReceiver: BroadcastReceiver? = null

    // In-app updater. Uses PackageInstaller sessions (reports real install
    // errors back to Dart) and falls back to an ACTION_VIEW intent.
    private fun setupInstaller(flutterEngine: FlutterEngine) {
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.ananta.ott/installer")
        installerChannel = ch
        registerInstallReceiver()
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "getCacheDir" -> result.success(cacheDir.absolutePath)
                "cleanup" -> {
                    cleanupUpdateFiles()
                    result.success(true)
                }
                "installApk" -> handleInstall(
                    call.argument<String>("path"),
                    call.argument<Boolean>("force") ?: false,
                    result
                )
                else -> result.notImplemented()
            }
        }
    }

    private fun cleanupUpdateFiles() {
        try {
            cacheDir.listFiles()?.forEach { f ->
                if (f.name.startsWith("ananta_update")) f.delete()
            }
        } catch (e: Exception) {
            // best effort
        }
    }

    private fun handleInstall(path: String?, force: Boolean, result: MethodChannel.Result) {
        try {
            val file = if (path != null) File(path) else null
            if (file == null || !file.exists()) {
                result.error("NO_FILE", "Downloaded APK not found", null)
                return
            }
            if (!force && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                openUnknownSourcesSettings()
                result.success("permission")
                return
            }
            // Copying ~80 MB into the session must not block the UI thread.
            Thread {
                try {
                    commitSession(file)
                    runOnUiThread { result.success("session") }
                } catch (e: Exception) {
                    try {
                        viewInstall(file)
                        runOnUiThread { result.success("started") }
                    } catch (e2: Exception) {
                        runOnUiThread {
                            result.error("INSTALL_FAILED", e2.javaClass.simpleName + ": " + e2.message, null)
                        }
                    }
                }
            }.start()
        } catch (e: Exception) {
            result.error("INSTALL_FAILED", e.javaClass.simpleName + ": " + e.message, null)
        }
    }

    private fun openUnknownSourcesSettings() {
        val attempts = listOf(
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")),
            Intent(Settings.ACTION_SECURITY_SETTINGS),
            Intent(Settings.ACTION_SETTINGS)
        )
        for (intent in attempts) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return
            } catch (e: Exception) {
                // try the next, more generic settings screen (TV firmwares differ)
            }
        }
    }

    private fun commitSession(file: File) {
        val installer = packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(packageName)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        val sessionId = installer.createSession(params)
        val session = installer.openSession(sessionId)
        try {
            file.inputStream().use { input ->
                session.openWrite("ananta_update", 0, file.length()).use { out ->
                    input.copyTo(out)
                    session.fsync(out)
                }
            }
            val intent = Intent(installAction).setPackage(packageName)
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) flags = flags or PendingIntent.FLAG_MUTABLE
            val pending = PendingIntent.getBroadcast(this, sessionId, intent, flags)
            session.commit(pending.intentSender)
        } catch (e: Exception) {
            try {
                session.abandon()
            } catch (e2: Exception) {
                // ignore
            }
            throw e
        } finally {
            session.close()
        }
    }

    private fun viewInstall(file: File) {
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        var install = Intent(Intent.ACTION_VIEW)
        install.setDataAndType(uri, "application/vnd.android.package-archive")
        install.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        for (ri in packageManager.queryIntentActivities(install, PackageManager.MATCH_DEFAULT_ONLY)) {
            grantUriPermission(ri.activityInfo.packageName, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivity(install)
        } catch (e: Exception) {
            // Some TV firmwares only handle the dedicated install action.
            install = Intent(Intent.ACTION_INSTALL_PACKAGE)
            install.setDataAndType(uri, "application/vnd.android.package-archive")
            install.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(install)
        }
    }

    private fun registerInstallReceiver() {
        if (installReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
                val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: ""
                if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
                    @Suppress("DEPRECATION")
                    val confirm: Intent? = if (Build.VERSION.SDK_INT >= 33) {
                        intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                    } else {
                        intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                    }
                    if (confirm != null) {
                        confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        try {
                            startActivity(confirm)
                        } catch (e: Exception) {
                            installerChannel?.invokeMethod(
                                "installStatus",
                                mapOf("status" to PackageInstaller.STATUS_FAILURE, "message" to ("Cannot open installer: " + e.message))
                            )
                            return
                        }
                    }
                }
                installerChannel?.invokeMethod("installStatus", mapOf("status" to status, "message" to message))
            }
        }
        val filter = IntentFilter(installAction)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
        }
        installReceiver = receiver
    }

    // When the user exits the app (Back/finish), end the process so no
    // audio keeps playing in the background (notably on Android TV).
    override fun onDestroy() {
        val finishing = isFinishing
        try {
            installReceiver?.let { unregisterReceiver(it) }
        } catch (e: Exception) {
            // ignore
        }
        installReceiver = null
        try { exo?.releaseAll() } catch (e: Exception) { /* ignore */ }
        exo = null
        super.onDestroy()
        if (finishing) {
            android.os.Process.killProcess(android.os.Process.myPid())
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Home / app switch while a stream is playing: keep it visible in PiP.
        if (pipEnabled && !isPipActive()) enterPip()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        window.decorView.setBackgroundColor(Color.TRANSPARENT)
        AnantaNotice.pip = isInPictureInPictureMode
        channel?.invokeMethod("pipChanged", isInPictureInPictureMode)
    }

    private fun isPipSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun isPipActive(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isInPictureInPictureMode

    private fun buildParams(): PictureInPictureParams {
        // Android only accepts aspect ratios between 1:2.39 and 2.39:1.
        val ratio = aspect.coerceIn(0.5, 2.39)
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational((ratio * 1000).toInt(), 1000))
        sourceRect?.let { builder.setSourceRectHint(it) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(pipEnabled)
        }
        return builder.build()
    }

    // Android 12+: system auto-enters PiP on Home gesture when enabled.
    private fun updateAutoEnter() {
        if (!isPipSupported() || isFinishing) return
        try {
            setPictureInPictureParams(buildParams())
        } catch (e: Exception) {
            // Ignore: params are best-effort.
        }
    }

    private fun enterPip(): Boolean {
        if (!isPipSupported() || isFinishing) return false
        return try {
            enterPictureInPictureMode(buildParams())
        } catch (e: Exception) {
            false
        }
    }
}


/** Fetches notice.json from the repository and shows a heads-up notification. */
object AnantaNotice {
    const val MANIFEST_URL =
        "https://raw.githubusercontent.com/Abidananta/Ananta-Stream-ott/refs/heads/main/notice.json"
    const val CHANNEL_ID = "ananta_notice_v2"
    const val JOB_ID = 7001
    private const val PREFS = "ananta_notice"

    @Volatile var resumed = false
    @Volatile var pip = false
    @Volatile var listener: ((Notice) -> Unit)? = null

    fun isTv(ctx: Context): Boolean {
        val ui = ctx.resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK
        return ui == Configuration.UI_MODE_TYPE_TELEVISION ||
            !ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN)
    }

    class Notice(val id: Long, val title: String, val body: String, val image: String, val url: String)

    fun fetch(): Notice? {
        val conn = URL("$MANIFEST_URL?t=${System.currentTimeMillis()}").openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 8000
            conn.readTimeout = 8000
            if (conn.responseCode != 200) return null
            val text = conn.inputStream.bufferedReader().use { it.readText() }
            val o = JSONObject(text)
            val id = o.optLong("id", 0)
            val title = o.optString("title", "").trim()
            val body = o.optString("body", "").trim()
            if (id <= 0 || (title.isEmpty() && body.isEmpty())) return null
            return Notice(id, title, body, o.optString("image", "").trim(), o.optString("url", "").trim())
        } finally {
            conn.disconnect()
        }
    }

    // ---- history (shown by the bell icon in the app) ----
    fun save(ctx: Context, n: Notice) {
        try {
            val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val old = org.json.JSONArray(prefs.getString("history", "[]") ?: "[]")
            val arr = org.json.JSONArray()
            arr.put(JSONObject().put("id", n.id).put("title", n.title).put("body", n.body)
                .put("image", n.image).put("url", n.url).put("time", System.currentTimeMillis()))
            for (i in 0 until minOf(old.length(), 49)) arr.put(old.get(i))
            prefs.edit().putString("history", arr.toString()).apply()
        } catch (e: Exception) {
            // ignore
        }
    }

    fun history(ctx: Context): String =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("history", "[]") ?: "[]"

    fun lastRead(ctx: Context): Long =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong("last_read", 0)

    fun markRead(ctx: Context) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putLong("last_read", System.currentTimeMillis()).apply()
    }

    fun clearHistory(ctx: Context) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("history", "[]").apply()
    }

    fun isNew(ctx: Context, n: Notice): Boolean =
        n.id > ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong("last_id", 0)

    fun markSeen(ctx: Context, n: Notice) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putLong("last_id", n.id).apply()
    }

    fun ensureChannel(ctx: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try { nm.deleteNotificationChannel("ananta_notice") } catch (e: Exception) { }
        val ch = NotificationChannel(CHANNEL_ID, "Announcements", NotificationManager.IMPORTANCE_HIGH)
        ch.description = "News and updates from Ananta OTT"
        ch.enableVibration(true)
        ch.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        nm.createNotificationChannel(ch)
    }

    private fun loadBitmap(url: String): Bitmap? {
        if (url.isEmpty()) return null
        return try {
            val bytes = (URL(url).openConnection() as HttpURLConnection).run {
                connectTimeout = 8000
                readTimeout = 10000
                try { inputStream.use { it.readBytes() } } finally { disconnect() }
            }
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            var sample = 1
            while (bounds.outWidth / sample > 1200) sample *= 2
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
        } catch (e: Exception) {
            null
        }
    }

    private fun rid(ctx: Context, type: String, name: String): Int =
        ctx.resources.getIdentifier(name, type, ctx.packageName)

    private fun circle(src: Bitmap, size: Int): Bitmap {
        val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val c = Canvas(out)
        val p = Paint(Paint.ANTI_ALIAS_FLAG)
        c.drawCircle(size / 2f, size / 2f, size / 2f, p)
        p.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
        val side = minOf(src.width, src.height)
        val l = (src.width - side) / 2
        val t = (src.height - side) / 2
        c.drawBitmap(src, android.graphics.Rect(l, t, l + side, t + side), android.graphics.Rect(0, 0, size, size), p)
        return out
    }

    // Center-crops to w:h and rounds the corners.
    private fun rounded(src: Bitmap, w: Int, h: Int, radius: Float): Bitmap {
        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(out)
        val p = Paint(Paint.ANTI_ALIAS_FLAG)
        c.drawRoundRect(RectF(0f, 0f, w.toFloat(), h.toFloat()), radius, radius, p)
        p.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
        val targetRatio = w.toFloat() / h
        var cw = src.width
        var ch = (cw / targetRatio).toInt()
        if (ch > src.height) { ch = src.height; cw = (ch * targetRatio).toInt() }
        val l = (src.width - cw) / 2
        val t = (src.height - ch) / 2
        c.drawBitmap(src, android.graphics.Rect(l, t, l + cw, t + ch), android.graphics.Rect(0, 0, w, h), p)
        return out
    }

    private fun card(ctx: Context, layout: Int, n: Notice, avatar: Bitmap?, big: Bitmap?): RemoteViews {
        val v = RemoteViews(ctx.packageName, layout)
        v.setTextViewText(rid(ctx, "id", "notice_title"), n.title)
        v.setTextViewText(rid(ctx, "id", "notice_body"), n.body)
        if (avatar != null) v.setImageViewBitmap(rid(ctx, "id", "notice_avatar"), avatar)
        val bigId = rid(ctx, "id", "notice_big")
        if (bigId != 0) {
            if (big != null) v.setImageViewBitmap(bigId, big) else v.setViewVisibility(bigId, android.view.View.GONE)
        }
        return v
    }

    @Suppress("DEPRECATION")
    fun post(ctx: Context, n: Notice) {
        save(ctx, n)
        ensureChannel(ctx)
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val bmp = loadBitmap(n.image)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, CHANNEL_ID) else Notification.Builder(ctx)
        var small = ctx.resources.getIdentifier("ic_launcher_monochrome", "drawable", ctx.packageName)
        if (small == 0) small = ctx.applicationInfo.icon
        b.setSmallIcon(small)
            .setContentTitle(n.title)
            .setContentText(n.body)
            .setAutoCancel(true)
            .setColor(0xFF9B87FF.toInt())
            .setCategory(Notification.CATEGORY_MESSAGE)
        if (Build.VERSION.SDK_INT < 26) {
            b.setPriority(Notification.PRIORITY_HIGH)
            b.setDefaults(Notification.DEFAULT_ALL)
        }
        b.setVisibility(Notification.VISIBILITY_PUBLIC)
        val collapsedId = rid(ctx, "layout", "notice_collapsed")
        val expandedId = rid(ctx, "layout", "notice_expanded")
        if (Build.VERSION.SDK_INT >= 24 && collapsedId != 0 && expandedId != 0) {
            // Light rounded "message card" with a round picture, like a chat
            // notification; the full picture shows when expanded. Also used on
            // the lock screen.
            val iconRes = rid(ctx, "drawable", "ananta_launcher_icon")
            val avatarSrc = bmp ?: (if (iconRes != 0) BitmapFactory.decodeResource(ctx.resources, iconRes) else null)
            val avatar = avatarSrc?.let { circle(it, 128) }
            val big = bmp?.let { rounded(it, 800, 400, 28f) }
            b.setStyle(Notification.DecoratedCustomViewStyle())
            b.setCustomContentView(card(ctx, collapsedId, n, avatar, null))
            b.setCustomBigContentView(card(ctx, expandedId, n, avatar, big))
            b.setCustomHeadsUpContentView(card(ctx, collapsedId, n, avatar, null))
        } else if (bmp != null) {
            b.setLargeIcon(bmp)
            b.setStyle(Notification.BigPictureStyle().bigPicture(bmp).bigLargeIcon(null as Bitmap?).setSummaryText(n.body))
        } else {
            b.setStyle(Notification.BigTextStyle().bigText(n.body))
        }
        val intent = (if (n.url.isNotEmpty()) Intent(Intent.ACTION_VIEW, Uri.parse(n.url))
            else ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)) ?: Intent()
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= 23) flags = flags or PendingIntent.FLAG_IMMUTABLE
        b.setContentIntent(PendingIntent.getActivity(ctx, n.id.toInt(), intent, flags))
        nm.notify(n.id.toInt(), b.build())
    }
}

/** Runs about every 15 min (also when the app is closed). */
class NoticeJobService : JobService() {
    override fun onStartJob(params: JobParameters): Boolean {
        val ctx = applicationContext
        Thread {
            try {
                if (!AnantaNotice.resumed) {
                    val n = AnantaNotice.fetch()
                    if (n != null && AnantaNotice.isNew(ctx, n)) {
                        AnantaNotice.markSeen(ctx, n)
                        AnantaNotice.post(ctx, n)
                    }
                }
            } catch (e: Exception) {
                // retried next period
            }
            jobFinished(params, false)
        }.start()
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean = true
}


/** Firebase Cloud Messaging: data messages {title, body, image, url} sent to topic "all". */
class AnantaMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val ctx = applicationContext
        if (AnantaNotice.isTv(ctx)) return
        val d = message.data
        val title = (d["title"] ?: message.notification?.title ?: "").trim()
        val body = (d["body"] ?: message.notification?.body ?: "").trim()
        val image = (d["image"] ?: message.notification?.imageUrl?.toString() ?: "").trim()
        val url = (d["url"] ?: "").trim()
        if (title.isEmpty() && body.isEmpty()) return
        val id = (System.currentTimeMillis() / 1000) and 0x3fffffff
        val n = AnantaNotice.Notice(id, title, body, image, url)
        val l = AnantaNotice.listener
        if (AnantaNotice.resumed && !AnantaNotice.pip && l != null) {
            AnantaNotice.save(ctx, n)
            l(n)
        } else {
            try { AnantaNotice.post(ctx, n) } catch (e: Exception) { }
        }
    }
}
