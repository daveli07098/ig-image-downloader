import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Resolves the persistent download folder for saved IG media.
///
/// Android : /storage/emulated/0/Download/ig_downloader/<username>/
///           (real public Downloads — visible in Files app and gallery)
/// iOS     : Documents/ig_downloader/<username>/
class StorageService {
  StorageService._();

  static const _folderName = 'ig_downloader';
  static const _storageChannel = MethodChannel('ig_downloader/storage');

  /// Returns the ig_downloader directory, creating it if needed.
  /// Files go directly here: /storage/emulated/0/Download/ig_downloader/
  static Future<Directory> getOrCreateSaveDir(String username) async {
    return getRootDir();
  }

  /// Root of the IG Downloader folder.
  static Future<Directory> getRootDir() async {
    final base = await _baseDir();
    final dir = Directory('${base.path}/$_folderName');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<Directory> _baseDir() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      // Use native channel to get the real public Downloads directory:
      // /storage/emulated/0/Download/
      // path_provider's getDownloadsDirectory() returns the app-private
      // sandbox (/Android/data/<pkg>/files/) which MediaScanner cannot index.
      try {
        final path = await _storageChannel.invokeMethod<String>(
          'getPublicDownloadsPath',
        );
        if (path != null && path.isNotEmpty) {
          return Directory(path);
        }
      } catch (e) {
        debugPrint('[Storage] getPublicDownloadsPath failed: $e');
      }
      // Fallback
      return (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
    }
    // iOS: app Documents directory is shown in Files app under the app name.
    return getApplicationDocumentsDirectory();
  }

  /// Human-readable label for displaying the save location.
  static String displayLabel(String fullPath) {
    final idx = fullPath.indexOf(_folderName);
    return idx >= 0 ? fullPath.substring(idx) : fullPath;
  }
}
