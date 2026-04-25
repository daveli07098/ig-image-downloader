import 'package:dio/dio.dart';
import 'package:gal/gal.dart';
import 'package:html/parser.dart' as html_parser;
import '../models/media_item.dart';
import 'storage_service.dart';

/// Fetches an Instagram page, extracts all media items (supports carousel
/// posts with multiple images/videos), and downloads selected items to the
/// device gallery.
class DownloaderService {
  final Dio _dio;

  DownloaderService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 60),
                headers: {
                  // Mimic a mobile browser so Instagram returns full og: tags
                  'User-Agent':
                      'Mozilla/5.0 (Linux; Android 14; Pixel 8) '
                      'AppleWebKit/537.36 (KHTML, like Gecko) '
                      'Chrome/124.0 Mobile Safari/537.36',
                  'Accept-Language': 'en-US,en;q=0.9',
                },
              ),
            );

  // ── 1.  Fetch all media items from an IG URL ───────────────────────────

  /// Returns a list of [MediaItem]s found in the post.
  /// Carousel posts may return multiple items; single posts return one.
  Future<List<MediaItem>> fetchItems(String igUrl) async {
    final response = await _dio.get<String>(igUrl);
    if (response.statusCode != 200 || response.data == null) {
      throw Exception(
          'Failed to load Instagram page (${response.statusCode})');
    }
    return _extractItems(response.data!);
  }

  List<MediaItem> _extractItems(String pageHtml) {
    final document = html_parser.parse(pageHtml);
    final metas = document.querySelectorAll('meta[property]');

    // Collect all og:video and og:image tags in order.
    // Instagram emits one og:video + one og:image per carousel item
    // (video posts have both; image-only posts have only og:image).
    final videos = <String>[];
    final images = <String>[];

    for (final tag in metas) {
      final property = tag.attributes['property'] ?? '';
      final content = tag.attributes['content'] ?? '';
      if (content.isEmpty) continue;

      if (property == 'og:video' || property == 'og:video:url') {
        videos.add(content);
      } else if (property == 'og:image') {
        images.add(content);
      }
    }

    final items = <MediaItem>[];

    if (videos.isNotEmpty) {
      for (var i = 0; i < videos.length; i++) {
        items.add(MediaItem(
          id: '$i',
          mediaUrl: videos[i],
          thumbnailUrl: i < images.length ? images[i] : null,
          type: MediaItemType.video,
        ));
      }
      // Remaining images beyond video count (mixed carousel)
      for (var i = videos.length; i < images.length; i++) {
        items.add(MediaItem(
          id: '$i',
          mediaUrl: images[i],
          thumbnailUrl: images[i],
          type: MediaItemType.image,
        ));
      }
    } else {
      for (var i = 0; i < images.length; i++) {
        items.add(MediaItem(
          id: '$i',
          mediaUrl: images[i],
          thumbnailUrl: images[i],
          type: MediaItemType.image,
        ));
      }
    }

    if (items.isEmpty) {
      throw Exception(
        'No downloadable media found.\n'
        'Private accounts and Stories require login.',
      );
    }

    return items;
  }

  // ── 2.  Download a single MediaItem ───────────────────────────────────

  /// Downloads [item] directly to the persistent save folder and also saves
  /// it to the device gallery. Returns the permanent file path.
  Future<String> downloadItem(
    MediaItem item, {
    required void Function(double progress) onProgress,
  }) async {
    final ext = item.isVideo ? 'mp4' : 'jpg';
    final saveDir = await StorageService.getOrCreateSaveDir();
    final filename =
        'ig_${DateTime.now().millisecondsSinceEpoch}_${item.id}.$ext';
    final savePath = '${saveDir.path}/$filename';

    await _dio.download(
      item.mediaUrl,
      savePath,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress(received / total);
      },
    );

    // Request gallery permission on first save (required on both platforms).
    // gal throws GalException.accessDenied if permission is not granted.
    if (!await Gal.hasAccess()) {
      final granted = await Gal.requestAccess();
      if (!granted) {
        throw Exception(
          'Gallery permission denied. '
          'Please allow Photos access in Settings to save media.',
        );
      }
    }

    // Also add to the device gallery so it appears in Photos / Gallery app.
    if (item.isVideo) {
      await Gal.putVideo(savePath);
    } else {
      await Gal.putImage(savePath);
    }

    return savePath;
  }
}
