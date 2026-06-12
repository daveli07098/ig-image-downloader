import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;

import '../models/media_item.dart';

/// Image extractor for LIHKG (lihkg.com) forum threads.
///
/// LIHKG is a single-page React app behind Cloudflare, so the server HTML of a
/// thread URL only contains the og:image — the actual post images load later
/// via its JSON API. We therefore pull images straight from the API:
///   https://lihkg.com/api_v2/thread/{threadId}/page/{page}?order=reply_time
/// Each reply's `msg` field is an HTML fragment; we collect every <img> in it.
///
/// Pages are fetched until an empty page or [_maxPages] is reached, so a long
/// thread still yields a bounded, de-duplicated set of images.
class LihkgDownloaderService {
  static const _ua =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  // Bound the crawl so a 50-page thread doesn't hammer the API or the UI.
  static const _maxPages = 5;

  final Dio _dio;

  LihkgDownloaderService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              headers: {
                'User-Agent': _ua,
                'Accept': 'application/json, text/plain, */*',
                'Accept-Language': 'zh-HK,zh;q=0.9,en;q=0.8',
                'Referer': 'https://lihkg.com/',
                'X-Requested-With': 'XMLHttpRequest',
              },
            ));

  /// True for any lihkg.com thread URL, e.g.
  ///   https://lihkg.com/thread/1234567
  ///   https://lihkg.com/thread/1234567/page/3
  static bool isLihkgUrl(String url) {
    final u = url.toLowerCase();
    return u.contains('lihkg.com/thread/');
  }

  static String? _threadId(String url) =>
      RegExp(r'lihkg\.com/thread/(\d+)').firstMatch(url)?.group(1);

  /// Extract all post images from a LIHKG thread.
  Future<List<MediaItem>> fetchItems(String url) async {
    final threadId = _threadId(url);
    if (threadId == null) {
      throw Exception('Not a recognised LIHKG thread URL.');
    }
    debugPrint('[LIHKG] thread $threadId');

    final seen = <String>{};
    final urls = <String>[];

    for (var page = 1; page <= _maxPages; page++) {
      final api =
          'https://lihkg.com/api_v2/thread/$threadId/page/$page?order=reply_time';
      try {
        // responseType json — but tolerate string bodies behind Cloudflare.
        final resp = await _dio.get<dynamic>(api);
        final data = resp.data is String
            ? jsonDecode(resp.data as String)
            : resp.data;
        if (data is! Map) break;
        if (data['success'] == 0 || data['success'] == false) {
          debugPrint('[LIHKG] api page $page not successful');
          break;
        }
        final items = (data['response'] as Map?)?['item_data'] as List?;
        if (items == null || items.isEmpty) break;

        for (final it in items) {
          final msg = (it as Map)['msg'] as String?;
          if (msg == null || msg.isEmpty) continue;
          for (final src in _imagesFromMsg(msg)) {
            if (seen.add(src)) urls.add(src);
          }
        }
        // Stop early once the thread is exhausted.
        final totalPage = (data['response'] as Map?)?['total_page'];
        if (totalPage is num && page >= totalPage) break;
      } catch (e) {
        debugPrint('[LIHKG] api page $page failed: $e');
        break;
      }
    }

    if (urls.isEmpty) {
      throw Exception(
        'No images found in this LIHKG thread.\n'
        'It may be text-only, or LIHKG blocked the request — try opening it in '
        'a browser first.',
      );
    }

    debugPrint('[LIHKG] ${urls.length} images');
    return [
      for (var i = 0; i < urls.length; i++)
        MediaItem(
          id: '$i',
          mediaUrl: urls[i],
          thumbnailUrl: urls[i],
          type: MediaItemType.image,
          username: 'lihkg_$threadId',
          itemIndex: i + 1,
        ),
    ];
  }

  /// Pull image URLs out of a reply's HTML `msg` fragment.
  static List<String> _imagesFromMsg(String msg) {
    final out = <String>[];
    final doc = html_parser.parse(msg);
    for (final img in doc.querySelectorAll('img')) {
      // LIHKG lazy-loads with data-src / data-original; src may be a spinner.
      final src = img.attributes['data-original'] ??
          img.attributes['data-src'] ??
          img.attributes['src'] ??
          '';
      if (src.startsWith('http') && !src.contains('/assets/')) {
        out.add(src);
      }
    }
    return out;
  }
}
