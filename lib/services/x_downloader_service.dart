import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../models/media_item.dart';

/// Fetches media items from an X (Twitter) post URL.
///
/// Uses the fxtwitter syndication API which returns structured JSON with
/// all media (photos + videos / GIF) for a public tweet — no auth needed.
///
/// URL format supported:
///   https://x.com/<user>/status/<tweet_id>
///   https://twitter.com/<user>/status/<tweet_id>
class XDownloaderService {
  static const _fxApiBase = 'https://api.fxtwitter.com';

  final Dio _dio;

  XDownloaderService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              headers: {
                'User-Agent': 'Mozilla/5.0 (compatible; IgDownloader/2.0)',
                'Accept': 'application/json',
              },
            ));

  // ── URL helpers ──────────────────────────────────────────────────────────

  static bool isXUrl(String url) =>
      url.contains('x.com/') || url.contains('twitter.com/');

  static final _statusPattern = RegExp(
    r'(?:x|twitter)\.com/([^/?#]+)/status/(\d+)',
    caseSensitive: false,
  );

  static String? extractTweetId(String url) =>
      _statusPattern.firstMatch(url)?.group(2);

  static String? extractUsername(String url) =>
      _statusPattern.firstMatch(url)?.group(1);

  // ── Fetch media items ────────────────────────────────────────────────────

  Future<List<MediaItem>> fetchItems(String xUrl) async {
    // Strip query params and fragment before parsing
    final clean = xUrl.split('?').first.split('#').first;
    final tweetId = extractTweetId(clean);
    final username = extractUsername(clean) ?? 'unknown';

    if (tweetId == null) {
      throw Exception('Could not extract tweet ID from URL: $xUrl');
    }

    debugPrint('[X] Fetching tweet $tweetId by @$username');
    return _fetchViaFxTwitter(username, tweetId);
  }

  Future<List<MediaItem>> _fetchViaFxTwitter(
      String username, String tweetId) async {
    final url = '$_fxApiBase/$username/status/$tweetId';
    debugPrint('[X] fxtwitter: $url');

    final resp = await _dio.get<String>(url);
    if (resp.statusCode != 200 || resp.data == null) {
      throw Exception('fxtwitter returned ${resp.statusCode}');
    }

    final json = jsonDecode(resp.data!) as Map<String, dynamic>;
    final code = json['code'] as int?;
    if (code != 200) {
      final msg = json['message'] ?? 'Error $code from fxtwitter';
      throw Exception(msg.toString());
    }

    final tweet = json['tweet'] as Map<String, dynamic>?;
    if (tweet == null) throw Exception('No tweet data returned');

    final screenName =
        (_dig(tweet, ['author', 'screen_name']) as String?) ?? username;
    final createdAt = tweet['created_at'] as String?;
    final postTimestamp = createdAt != null
        ? DateTime.tryParse(createdAt)?.millisecondsSinceEpoch != null
            ? DateTime.tryParse(createdAt)!.millisecondsSinceEpoch ~/ 1000
            : null
        : null;

    final mediaNode = tweet['media'] as Map<String, dynamic>?;
    if (mediaNode == null) {
      throw Exception('This tweet has no media attachments.');
    }

    final allMedia = (mediaNode['all'] as List?)
            ?.cast<Map<String, dynamic>>() ??
        [];
    if (allMedia.isEmpty) {
      throw Exception('This tweet has no media attachments.');
    }

    debugPrint('[X] ${allMedia.length} media items from @$screenName');

    final items = <MediaItem>[];
    for (var i = 0; i < allMedia.length; i++) {
      final m = allMedia[i];
      final type = m['type'] as String?;

      if (type == 'photo') {
        final rawUrl = m['url'] as String?;
        if (rawUrl != null) {
          final origUrl = _toOriginalQuality(rawUrl);
          items.add(MediaItem(
            id: '$i',
            mediaUrl: origUrl,
            thumbnailUrl: rawUrl,
            type: MediaItemType.image,
            username: screenName,
            itemIndex: i + 1,
            postTimestamp: postTimestamp,
          ));
        }
      } else if (type == 'video' || type == 'gif') {
        final thumbUrl = m['thumbnail_url'] as String?;
        final variants =
            (m['variants'] as List?)?.cast<Map<String, dynamic>>();
        final videoUrl = _bestVariant(variants);
        if (videoUrl != null) {
          items.add(MediaItem(
            id: '$i',
            mediaUrl: videoUrl,
            thumbnailUrl: thumbUrl,
            type: MediaItemType.video,
            username: screenName,
            itemIndex: i + 1,
            postTimestamp: postTimestamp,
          ));
        }
      }
    }

    if (items.isEmpty) {
      throw Exception(
        'No downloadable media found.\n'
        'Only public tweets with photos or videos are supported.',
      );
    }
    return items;
  }

  /// Returns the highest-bitrate mp4 variant URL from a list of video variants.
  String? _bestVariant(List<Map<String, dynamic>>? variants) {
    if (variants == null || variants.isEmpty) return null;
    final mp4 = variants
        .where((v) => (v['content_type'] as String?)?.contains('mp4') ?? false)
        .toList()
      ..sort((a, b) =>
          ((b['bitrate'] as num?) ?? 0).compareTo((a['bitrate'] as num?) ?? 0));
    return mp4.isNotEmpty
        ? mp4.first['url'] as String?
        : variants.first['url'] as String?;
  }

  /// Convert a pbs.twimg.com thumbnail URL to the named=orig variant for
  /// maximum quality (original upload resolution).
  String _toOriginalQuality(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host != 'pbs.twimg.com') return url;
    // Strip extension so we can add format+name query params
    final path = uri.path.replaceAll(RegExp(r'\.[a-zA-Z]+$'), '');
    return uri.replace(path: path, queryParameters: {
      'format': 'jpg',
      'name': 'orig',
    }).toString();
  }

  dynamic _dig(dynamic obj, List<Object> path) {
    dynamic cur = obj;
    for (final key in path) {
      if (cur == null) return null;
      if (key is int && cur is List) {
        cur = cur.length > key ? cur[key] : null;
      } else if (key is String && cur is Map) {
        cur = cur[key];
      } else {
        return null;
      }
    }
    return cur;
  }
}
