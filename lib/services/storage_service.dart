import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Resolves the persistent download folder for saved IG media.
///
/// Android : [getExternalStorageDirectory]/IG Downloader/YYYY-MM-DD/
///           → visible in the device Files app under "Android/data/…"
/// iOS     : [getApplicationDocumentsDirectory]/IG Downloader/YYYY-MM-DD/
///           → visible in the iOS Files app under "On My iPhone → IG Downloader"
class StorageService {
  StorageService._();

  static const _folderName = 'IG Downloader';

  /// Returns the date-stamped sub-directory for today's downloads,
  /// creating it on disk if it doesn't exist yet.
  static Future<Directory> getOrCreateSaveDir() async {
    final base = await _baseDir();
    final dateTag = _dateTag();
    final dir = Directory('${base.path}/$_folderName/$dateTag');
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

  static String _dateTag() {
    final now = DateTime.now();
    return '${now.year}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  /// Human-readable label for displaying the save location.
  static String displayLabel(String fullPath) {
    // Show only the IG Downloader/… portion for brevity.
    final idx = fullPath.indexOf(_folderName);
    return idx >= 0 ? fullPath.substring(idx) : fullPath;
  }
}
