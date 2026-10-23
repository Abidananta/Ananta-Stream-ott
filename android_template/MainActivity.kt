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
import android.provider.Settings
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

    // Older builds also created "Android/data/<pkg>/files/Ananta OTT". Merge any such
    // duplicate into the single active folder and delete it.
    private fun mergeDuplicateStorageFolders(active: File) {
        try {
            val others = listOf(
                getExternalFilesDir(null)?.let { File(it, "Ananta OTT") },
                File(filesDir, "Ananta OTT")
            )
            for (other in others) {
                if (other == null || !other.exists()) continue
                if (other.canonicalPath == active.canonicalPath) continue
                try {
                    other.copyRecursively(active, overwrite = false)
                } catch (e: Exception) {
                    // keep going: the copy is best-effort
                }
                other.deleteRecursively()
            }
        } catch (e: Exception) {
            // ignore
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
                                // No file-manager access yet: use the app's PRIVATE folder
                                // (not visible in the file manager) so the user never ends up
                                // with a second visible "Ananta OTT" folder.
                                dir = File(filesDir, "Ananta OTT")
                                dir.mkdirs()
                            }
                            mergeDuplicateStorageFolders(dir)
                            result.success(mapOf("path" to dir.absolutePath, "public" to isPublic))
                        } catch (e: Exception) {
                            result.error("STORAGE_FAILED", e.javaClass.simpleName + ": " + e.message, null)
                        }
                    }
                    "requestStorageAccessOnce" -> {
                        val prefs = getSharedPreferences("ananta_storage", Context.MODE_PRIVATE)
                        if (hasPublicStorageAccess() || prefs.getBoolean("asked", false)) {
                            result.success(false)
                        } else {
                            prefs.edit().putBoolean("asked", true).apply()
                            result.success(requestStorageAccess())
                        }
                    }
                    else -> result.notImplemented()
                }
            }
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
