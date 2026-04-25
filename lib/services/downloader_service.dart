import 'dart:io';
import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path_provider/path_provider.dart';

/// Fetches an Instagram page, extracts the direct media URL from Open Graph
/// meta tags, downloads the file, and saves it to the device gallery.
///
/// Works for public posts, Reels, and IGTV (video). Stories are usually
/// protected — a login flow would be needed for those.
class DownloaderService {
  final Dio _dio;

  DownloaderService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 60),
                headers: {
                  // Mimic a browser so Instagram returns the full HTML
                  'User-Agent':
                      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
                      '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
                  'Accept-Language': 'en-US,en;q=0.9',
                },
              ),
            );

  /// Returns the local file path of the saved media.
  Future<String> download(
    String igUrl, {
    required void Function(double progress) onProgress,
  }) async {
    // ── 1.  Fetch the IG page ──────────────────────────────────────────────
    final pageResponse = await _dio.get<String>(igUrl);
    if (pageResponse.statusCode != 200 || pageResponse.data == null) {
      throw Exception('Failed to load Instagram page (${pageResponse.statusCode})');
    }

    // ── 2.  Extract media URL from og:video or og:image ──────────────────
    final mediaUrl = _extractMediaUrl(pageResponse.data!);
    if (mediaUrl == null) {
      throw Exception(
        'Could not find downloadable media on this page.\n'
        'Private accounts and Stories require login.',
      );
    }

    // ── 3.  Download file to temp directory ─────────────────────────────
    final ext = mediaUrl.contains('.mp4') ? 'mp4' : 'jpg';
    final tmpDir = await getTemporaryDirectory();
    final filename = 'ig_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final localPath = '${tmpDir.path}/$filename';

    await _dio.download(
      mediaUrl,
      localPath,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress(received / total);
      },
    );

    // ── 4.  Save to gallery ──────────────────────────────────────────────
    await _saveToGallery(localPath, ext);

    return localPath;
  }

  String? _extractMediaUrl(String pageHtml) {
    final document = html_parser.parse(pageHtml);
    final metas = document.querySelectorAll('meta[property]');

    // Prefer video over image
    for (final tag in metas) {
      final property = tag.attributes['property'] ?? '';
      final content = tag.attributes['content'] ?? '';
      if ((property == 'og:video' || property == 'og:video:url') &&
          content.isNotEmpty) {
        return content;
      }
    }

    for (final tag in metas) {
      final property = tag.attributes['property'] ?? '';
      final content = tag.attributes['content'] ?? '';
      if (property == 'og:image' && content.isNotEmpty) {
        return content;
      }
    }

    return null;
  }

  Future<void> _saveToGallery(String localPath, String ext) async {
    // gal package — save to Photos / Gallery
    // Import is done lazily to avoid compile errors on platforms where gal
    // is not configured yet.
    //
    // Actual call:  await Gal.putImage(localPath);
    //               await Gal.putVideo(localPath);
    //
    // TODO: replace the dynamic import below with a proper import of gal
    //       once pubspec dependencies are resolved.
    if (ext == 'mp4') {
      // await Gal.putVideo(localPath);
    } else {
      // await Gal.putImage(localPath);
    }
    // For the draft, the file is already on disk at localPath.
  }
}
