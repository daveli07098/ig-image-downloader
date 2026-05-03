package com.daveli.igdownloader.ig_downloader

import android.media.MediaScannerConnection
import android.os.Environment
import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ig_downloader/cookies")
            .setMethodCallHandler { call, result ->
                if (call.method == "getCookie") {
                    val url = call.argument<String>("url") ?: ""
                    val cookie = CookieManager.getInstance().getCookie(url) ?: ""
                    result.success(cookie)
                } else {
                    result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ig_downloader/storage")
            .setMethodCallHandler { call, result ->
                if (call.method == "getPublicDownloadsPath") {
                    // Returns the real public Downloads folder:
                    // /storage/emulated/0/Download/
                    // This is user-visible and fully indexable by MediaScanner.
                    val dir = Environment.getExternalStoragePublicDirectory(
                        Environment.DIRECTORY_DOWNLOADS
                    )
                    result.success(dir.absolutePath)
                } else {
                    result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ig_downloader/media_scanner")
            .setMethodCallHandler { call, result ->
                if (call.method == "scanFile") {
                    val path = call.argument<String>("path")
                    val mimeType = call.argument<String>("mimeType")
                    if (path != null) {
                        MediaScannerConnection.scanFile(
                            applicationContext,
                            arrayOf(path),
                            arrayOf(mimeType),
                            null,
                        )
                        result.success(null)
                    } else {
                        result.error("INVALID_ARG", "path is required", null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }
}
