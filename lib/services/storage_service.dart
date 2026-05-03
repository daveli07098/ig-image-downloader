import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Resolves the persistent download folder for saved IG media.
///
/// Android : Downloads/ig_downloader/<username>/
/// iOS     : Documents/ig_downloader/<username>/
class StorageService {
  StorageService._();

  static const _folderName = 'ig_downloader';

  /// Returns the per-account sub-directory, creating it if needed.
  static Future<Directory> getOrCreateSaveDir(String username) async {
    final base = await _baseDir();
    final safe = _safeName(username);
    final dir = Directory('${base.path}/$_folderName/$safe');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Root of the IG Downloader folder (no date sub-dir).
  static Future<Directory> getRootDir() async {
    final base = await _baseDir();
    final dir = Directory('${base.path}/$_folderName');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<Directory> _baseDir() async {
    if (Platform.isAndroid) {
      // External storage is user-visible in the Files app.
      // Falls back to internal documents if external is unavailable.
      return (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
    }
    // iOS: app Documents directory is shown in Files app under the app name.
    return getApplicationDocumentsDirectory();
  }

  static String _safeName(String username) {
    // Strip any chars that aren't safe for folder names
    return username.replaceAll(RegExp(r'[^A-Za-z0-9._\-]'), '_');
  }

  /// Human-readable label for displaying the save location.
  static String displayLabel(String fullPath) {
    // Show only the IG Downloader/… portion for brevity.
    final idx = fullPath.indexOf(_folderName);
    return idx >= 0 ? fullPath.substring(idx) : fullPath;
  }
}
