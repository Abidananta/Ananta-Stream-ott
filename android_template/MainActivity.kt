package com.ananta.ott

import android.Manifest
import android.app.PendingIntent
import android.os.Environment
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
import android.provider.MediaStore
import android.provider.Settings
import android.content.ContentUris
import android.content.ContentValues
import java.util.concurrent.Executors
import androidx.core.content.FileProvider
import java.io.File
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.ananta.ott/pip"
    private var channel: MethodChannel? = null
    // True only while a stream is playing; gates Home/Recents auto-PiP.
    private var pipEnabled = false
    private var aspect = 16.0 / 9.0
    // Video area (screen pixels) used as PiP source rect for a smooth start.
    private var sourceRect: Rect? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Black behind Flutter: nothing white can show while the PiP window resizes.
        window.setBackgroundDrawable(ColorDrawable(Color.BLACK))
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupInstaller(flutterEngine)
        setupStorage(flutterEngine)
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

    // ------------------------------------------------------------------
    // Storage: an "Ananta OTT" folder in the internal storage (visible in the
    // file manager) that holds the cached EPG files and channel logos.
    // Needs "All files access" on Android 11+ (storage permission on 6-10);
    // without it the app-specific external folder is used instead.
    // ------------------------------------------------------------------
    private fun hasPublicStorageAccess(): Boolean {
        return when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> Environment.isExternalStorageManager()
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M ->
                checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
            else -> true
        }
    }

    private fun setupStorage(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.ananta.ott/storage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getStorageRoot" -> {
                        try {
                            var isPublic = false
                            var dir: File? = null
                            if (hasPublicStorageAccess() && Environment.getExternalStorageState() == Environment.MEDIA_MOUNTED) {
                                val candidate = File(Environment.getExternalStorageDirectory(), "Ananta OTT")
                                if (candidate.exists() || candidate.mkdirs()) {
                                    dir = candidate
                                    isPublic = true
                                }
                            }
                            if (dir == null) {
                                val base = getExternalFilesDir(null) ?: filesDir
                                dir = File(base, "Ananta OTT")
                                dir.mkdirs()
                            }
                            result.success(mapOf("path" to dir.absolutePath, "public" to isPublic))
                        } catch (e: Exception) {
                            result.error("STORAGE_FAILED", e.javaClass.simpleName + ": " + e.message, null)
                        }
                    }
                    "requestStorageAccessOnce" -> {
                        // Ask at most 3 times, and only count an ask that really
                        // opened a screen / dialog (many TV firmwares have none).
                        val prefs = getSharedPreferences("ananta_storage", Context.MODE_PRIVATE)
                        val asks = prefs.getInt("asks", 0)
                        if (hasPublicStorageAccess() || asks >= 3) {
                            result.success(false)
                        } else {
                            val opened = requestStorageAccess()
                            if (opened) prefs.edit().putInt("asks", asks + 1).apply()
                            result.success(opened)
                        }
                    }
                    // Copies a cached file into the PUBLIC folder
                    // Documents/Ananta OTT/<dir>/ through MediaStore. Needs no
                    // permission (Android 10+), so the folder shows up in every
                    // file manager even when "All files access" is unavailable.
                    "mirrorFile" -> {
                        val path = call.argument<String>("path")
                        val dir = call.argument<String>("dir") ?: ""
                        val name = call.argument<String>("name")
                        val overwrite = call.argument<Boolean>("overwrite") ?: false
                        if (path == null || name == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                            result.success(false)
                        } else {
                            mirrorExecutor.execute {
                                val ok = try {
                                    mirrorFile(File(path), dir, name, overwrite)
                                } catch (e: Exception) {
                                    false
                                }
                                runOnUiThread { result.success(ok) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private val mirrorExecutor = Executors.newSingleThreadExecutor()

    private fun mimeFor(name: String): String {
        val n = name.lowercase()
        return when {
            n.endsWith(".png") -> "image/png"
            n.endsWith(".jpg") || n.endsWith(".jpeg") -> "image/jpeg"
            n.endsWith(".webp") -> "image/webp"
            n.endsWith(".gif") -> "image/gif"
            n.endsWith(".svg") -> "image/svg+xml"
            n.endsWith(".txt") -> "text/plain"
            n.endsWith(".json") -> "application/json"
            n.endsWith(".xml") -> "text/xml"
            else -> "application/octet-stream" // .gz, .part, unknown
        }
    }

    private fun mirrorFile(src: File, dir: String, name: String, overwrite: Boolean): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || !src.exists() || src.length() == 0L) return false
        val resolver = contentResolver
        val collection = MediaStore.Files.getContentUri("external")
        val cleanDir = dir.trim('/').let { if (it.isEmpty()) "" else "$it/" }
        val rel = "Documents/Ananta OTT/$cleanDir"
        var existing: Uri? = null
        resolver.query(
            collection,
            arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.MediaColumns.DISPLAY_NAME}=? AND ${MediaStore.MediaColumns.RELATIVE_PATH}=?",
            arrayOf(name, rel),
            null
        )?.use { c -> if (c.moveToFirst()) existing = ContentUris.withAppendedId(collection, c.getLong(0)) }
        if (existing != null && !overwrite) return true
        var target: Uri? = existing
        if (target == null) {
            for (mime in listOf(mimeFor(name), "application/octet-stream")) {
                try {
                    val values = ContentValues().apply {
                        put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                        put(MediaStore.MediaColumns.MIME_TYPE, mime)
                        put(MediaStore.MediaColumns.RELATIVE_PATH, rel)
                    }
                    target = resolver.insert(collection, values)
                    if (target != null) break
                } catch (e: Exception) {
                    // directory/type combination refused: retry as a generic file
                }
            }
        }
        val uri = target ?: return false
        val out = resolver.openOutputStream(uri, "wt") ?: return false
        out.use { o -> src.inputStream().use { it.copyTo(o) } }
        return true
    }

    private fun requestStorageAccess(): Boolean {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val attempts = listOf(
                    Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName")),
                    Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                )
                for (intent in attempts) {
                    try {
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        return true
                    } catch (e: Exception) {
                        // not available on this firmware (many TV boxes)
                    }
                }
                return false
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), 4711)
                return true
            }
        } catch (e: Exception) {
            // ignore, the app-specific folder is used
        }
        return false
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
                            result.error(
                                "INSTALL_FAILED",
                                "session: " + e.javaClass.simpleName + ": " + e.message +
                                    " | view: " + e2.javaClass.simpleName + ": " + e2.message,
                                null
                            )
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
