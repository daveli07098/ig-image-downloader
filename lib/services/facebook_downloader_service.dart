import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import '../models/media_item.dart';

/// Downloads media from Facebook posts, videos, and Reels.
///
/// Primary strategy: facebookexternalhit UA — Facebook renders fully-populated
/// OG tags for this UA without JavaScript execution. Works for public content.
/// For video/reel pages, og:video is intentionally omitted by Facebook; instead,
/// the real MP4 URL is fetched from /video/embed?video_id=<id> which returns
/// hd_src/sd_src in its JSON payload.
///
/// NEVER mix user session cookies with facebookexternalhit UA — that combination
/// is an instant automation detection signal. User cookies are only used in the
/// browser-UA fallback when bot UA finds nothing (private content).
///
/// URL formats supported:
///   https://www.facebook.com/share/XXXXXXXX/         (post/photo)
///   https://www.facebook.com/share/r/XXXXXXXX/       (reel/video)
///   https://www.facebook.com/<user>/videos/<id>/
///   https://www.facebook.com/<user>/posts/<id>/
///   https://www.facebook.com/reel/<id>/
class FacebookDownloaderService {
  // Bot UA: causes Facebook to render full OG tags for anonymous/public content.
  static const _botUA =
      'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)';

  // Browser UA: used for authenticated requests so they look like a real user.
  // Never mix this with facebookexternalhit — bots don't have user sessions.
  static const _browserUA =
      'Mozilla/5.0 (Linux; Android 14; SM-S928B) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.6367.82 Mobile Safari/537.36';

  // Desktop Chrome UA for authenticated fetch requests.
  // MUST be desktop (not Android/iOS mobile) — when Facebook receives an
  // authenticated request from a mobile UA, it responds with a 302 redirect
  // to intent://native_post/... (Android) or fb:// (iOS), which Dio cannot
  // follow and crashes. Desktop UAs always get proper HTML back.
  static const _authUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  // iOS Safari UA for mbasic.facebook.com — the basic server-rendered Facebook
  // web UI for devices without the app. Serves plain HTML to mobile UAs without
  // redirecting to fb:// or intent:// (those redirects only happen on
  // www.facebook.com; mbasic IS the app-free web version by design).
  static const _mbasicUA =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Mobile/15E148 Safari/604.1';

  final Dio _dio;

  FacebookDownloaderService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              followRedirects: true,
              maxRedirects: 8,
              headers: {
                'User-Agent': _botUA,
                'Accept-Language': 'en-US,en;q=0.9',
              },
            ));

  // ── URL helpers ──────────────────────────────────────────────────────────

  static bool isFacebookUrl(String url) =>
      RegExp(r'facebook\.com|fb\.com', caseSensitive: false).hasMatch(url);

  /// Extract a display username from a Facebook URL after redirect resolves.
  static String _usernameFromUrl(String url) {
    final re = RegExp(
      r'facebook\.com/([^/?#]+)/(?:videos|posts|reels)',
      caseSensitive: false,
    );
    final m = re.firstMatch(url);
    if (m != null) {
      final raw = m.group(1)!;
      // Skip numeric profile IDs and generic path segments
      if (!RegExp(r'^\d+$').hasMatch(raw) && raw != 'reel') return raw;
    }
    // /reel/<id>/ pattern
    final reelRe = RegExp(r'facebook\.com/reel/(\d+)', caseSensitive: false);
    if (reelRe.hasMatch(url)) return 'facebook_reel';
    return 'facebook';
  }

  // ── Fetch media items ────────────────────────────────────────────────────

  /// [fbCookies] — the full Facebook cookie string captured from the WebView
  /// login (contains c_user, xs, datr, etc.). When provided, authenticated
  /// pages are used as a private-content fallback after public fetch fails.
  Future<List<MediaItem>> fetchItems(String url, {String? fbCookies}) async {
    final cleanUrl = url.split('?').first;
    debugPrint('[FB] URL: $cleanUrl  session: ${fbCookies != null ? 'YES' : 'NO'}');

    // Always fetch with bot UA first — Facebook returns full OG tags for
    // facebookexternalhit and the response is reliably parseable.
    // Browser UA returns a React SPA without OG tags, so it cannot be used
    // for the primary fetch. User cookies are NEVER sent with the bot UA
    // request (mixing the two is an automation detection signal).
    final resp = await _dio.get<String>(cleanUrl);

    if (resp.statusCode != 200 || resp.data == null) {
      throw Exception('Failed to load Facebook page (${resp.statusCode})');
    }

    final html = resp.data!;
    final finalUrl = resp.realUri.toString();
    final username = _usernameFromUrl(finalUrl);
    debugPrint('[FB] final URL: $finalUrl  username: $username');

    // ── Parse OG tags ─────────────────────────────────────────────────────
    final document = html_parser.parse(html);
    String? ogVideoUrl;
    String? ogType;
    String? ogUrl;
    final ogImages = <String>[];

    for (final tag in document.querySelectorAll('meta[property]')) {
      final property = tag.attributes['property'] ?? '';
      final content = tag.attributes['content'] ?? '';
      if (content.isEmpty) continue;

      if ((property == 'og:video' ||
              property == 'og:video:url' ||
              property == 'og:video:secure_url') &&
          ogVideoUrl == null) {
        ogVideoUrl = content;
      } else if (property == 'og:image' ||
          property == 'og:image:url' ||
          property == 'og:image:secure_url') {
        if (!content.contains('static.xx.fbcdn') &&
            !content.contains('/rsrc.php/') &&
            !ogImages.contains(content)) {
          ogImages.add(content);
        }
      } else if (property == 'og:type' && ogType == null) {
        ogType = content;
      } else if (property == 'og:url' && ogUrl == null) {
        ogUrl = content;
      }
    }

    // ── Carousel image extraction from page JSON ───────────────────────────
    final allImages = List<String>.from(ogImages);
    _extractCarouselImagesFromJson(html, allImages);

    // Detect video pages by og:type OR URL patterns. Facebook reel URLs often
    // omit og:type=video when served to the facebookexternalhit bot UA.
    final isVideoPage = (ogType != null && ogType!.startsWith('video')) ||
        finalUrl.contains('/reel/') ||
        cleanUrl.contains('/share/r/');

    // ── Real video URL extraction ──────────────────────────────────────────
    // og:video from Facebook is typically an embed iframe URL, not an MP4.
    // Strategy:
    //   1. If og:video is already a real CDN video URL, use it directly.
    //   2. Try to extract from JSON in the main page source.
    //   3. Fetch the embed URL itself and look for <video> or JSON video data.
    String? realVideoUrl;

    // Only accept og:video as a real CDN video URL on confirmed video pages.
    // Photo posts can have og:video pointing to a Facebook auto-generated slideshow
    // MP4 — treating it as realVideoUrl would cause the first item to show as a
    // video and skip all the actual post photos.
    if (isVideoPage && ogVideoUrl != null) {
      final isRealCdn = ogVideoUrl.contains('fbcdn.net') &&
          !ogVideoUrl.contains('embed') &&
          !ogVideoUrl.contains('video.php');
      if (isRealCdn) {
        realVideoUrl = ogVideoUrl;
      }
    }

    // Only scan the bot UA HTML for video URLs on confirmed video pages.
    // For photo posts the facebookexternalhit response can include og:video meta
    // tags (auto-generated slideshows) that _extractVideoUrlFromJson would match,
    // producing a false realVideoUrl that hides all the actual post photos.
    if (isVideoPage) {
      realVideoUrl ??= _extractVideoUrlFromJson(html);
    }

    // ── Video embed URL strategy ────────────────────────────────────────
    // Facebook reels/videos never include og:video in bot UA responses — the
    // actual MP4 URL lives in the /video/embed?video_id=<id> endpoint.
    // When og:type starts with "video" and no MP4 found yet, extract the video
    // ID from the resolved og:url or final URL and fetch the embed page.
    // Also try the Facebook video plugin URL for posts without a direct video ID.
    if (realVideoUrl == null && isVideoPage) {
      // Prefer finalUrl (resolved URL, clean numeric IDs).
      // ogUrl may use pfbid or contain a Chinese title before the numeric ID.
      final videoId = _extractVideoIdFromUrl(finalUrl) ??
          (ogUrl != null ? _extractVideoIdFromUrl(ogUrl) : null);
      if (videoId != null) {
        try {
          final embedUrl =
              'https://www.facebook.com/video/embed?video_id=$videoId';
          debugPrint('[FB] Trying video embed endpoint: $embedUrl');
          final embedDio = Dio(BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 30),
            followRedirects: true,
            maxRedirects: 8,
            headers: {
              'User-Agent': _botUA,
              'Accept-Language': 'en-US,en;q=0.9',
            },
          ));
          final embedResp = await embedDio.get<String>(embedUrl);
          if (embedResp.statusCode == 200 && embedResp.data != null) {
            realVideoUrl = _extractVideoUrlFromJson(embedResp.data!);
            debugPrint(
                '[FB] Embed endpoint video: ${realVideoUrl != null ? "found" : "not found"}');
          }
        } catch (e) {
          debugPrint('[FB] Video embed fetch failed: $e');
        }
      }

      // If still no video ID found (e.g. og:url is /posts/<id>), try the
      // Facebook video plugin endpoint using the resolved post URL directly.
      if (realVideoUrl == null && (ogUrl ?? finalUrl).isNotEmpty) {
        try {
          final postUrl = Uri.encodeComponent(ogUrl ?? finalUrl);
          final pluginUrl =
              'https://www.facebook.com/plugins/video.php?href=$postUrl';
          debugPrint('[FB] Trying video plugin URL: $pluginUrl');
          final pluginDio = Dio(BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 30),
            followRedirects: true,
            maxRedirects: 8,
            headers: {
              'User-Agent': _botUA,
              'Accept-Language': 'en-US,en;q=0.9',
            },
          ));
          final pluginResp = await pluginDio.get<String>(pluginUrl);
          if (pluginResp.statusCode == 200 && pluginResp.data != null) {
            realVideoUrl = _extractVideoUrlFromJson(pluginResp.data!) ??
                _extractVideoTagSrc(pluginResp.data!);
            debugPrint(
                '[FB] Plugin URL video: ${realVideoUrl != null ? "found" : "not found"}');
          }
        } catch (e) {
          debugPrint('[FB] Video plugin fetch failed: $e');
        }
      }
    }

    // Legacy: if ogVideoUrl is an embed/php URL (not a CDN URL), fetch it
    if (realVideoUrl == null && ogVideoUrl != null) {
      final isEmbedUrl = ogVideoUrl.contains('embed') ||
          ogVideoUrl.contains('video.php') ||
          !ogVideoUrl.contains('fbcdn.net');
      if (isEmbedUrl) {
        try {
          debugPrint('[FB] Fetching legacy embed URL: $ogVideoUrl');
          final embedDio = Dio(BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 30),
            followRedirects: true,
            maxRedirects: 8,
            headers: {
              'User-Agent': _botUA,
              'Accept-Language': 'en-US,en;q=0.9',
            },
          ));
          final embedResp = await embedDio.get<String>(ogVideoUrl);
          if (embedResp.statusCode == 200 && embedResp.data != null) {
            final embedHtml = embedResp.data!;
            realVideoUrl = _extractVideoUrlFromJson(embedHtml) ??
                _extractVideoTagSrc(embedHtml);
            debugPrint(
                '[FB] Legacy embed video: ${realVideoUrl != null ? "found" : "not found"}');
          }
        } catch (e) {
          debugPrint('[FB] Legacy embed fetch failed: $e');
        }
      }
    }

    // ── Auth fetch for video pages ─────────────────────────────────────────
    // Only when on a confirmed video page and no MP4 URL found yet.
    // Desktop auth HTML includes playable_url JSON for the actual video.
    // NOT used for photo pages — desktop auth HTML is the full Facebook feed SPA
    // (ads, recommendations, sidebar); any video URL found there would be a false
    // positive from an unrelated post, not the shared photo album.
    if (fbCookies != null && isVideoPage && realVideoUrl == null) {
      debugPrint('[FB] Auth fetch for video (no URL found yet)');
      try {
        // Small random delay before authenticated fetch — breaks the pattern of
        // back-to-back requests with millisecond precision, which is a reliable
        // signal for automation detection systems.
        await Future.delayed(
            Duration(milliseconds: 500 + Random().nextInt(1500)));
        final earlyAuthDio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          followRedirects: true,
          maxRedirects: 8,
          headers: {
            // Desktop UA — avoids intent:// / fb:// deep-link redirects.
            'User-Agent': _authUA,
            'Cookie': fbCookies,
            // sec-fetch-site: none = direct navigation (URL typed / opened from
            // an external app). 'same-origin' would mean the request originated
            // from within Facebook — incorrect and a detectable inconsistency.
            // No Referer header on direct navigation (same reason).
            'sec-fetch-dest': 'document',
            'sec-fetch-mode': 'navigate',
            'sec-fetch-site': 'none',
            'sec-fetch-user': '?1',
            // Chrome client hints — Chrome sends these for all HTTPS navigations.
            'sec-ch-ua':
                '"Chromium";v="124", "Google Chrome";v="124", "Not-A.Brand";v="99"',
            'sec-ch-ua-mobile': '?0',
            'sec-ch-ua-platform': '"Windows"',
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
            'Accept-Language': 'en-US,en;q=0.9',
            'Upgrade-Insecure-Requests': '1',
          },
        ));
        // Use the redirect-resolved URL — share URLs (/share/...) may redirect
        // to a different canonical URL depending on UA; using the already-resolved
        // final URL avoids an extra redirect hop and gives more reliable HTML.
        final resolvedUrl =
            finalUrl.isNotEmpty ? finalUrl.split('?').first : cleanUrl;
        final authResp = await earlyAuthDio.get<String>(resolvedUrl);
        if (authResp.statusCode == 200 && authResp.data != null) {
          realVideoUrl = _extractVideoUrlFromJson(authResp.data!);
          debugPrint('[FB] Auth result: video=${realVideoUrl != null}');
        }
      } catch (e) {
        debugPrint('[FB] Auth fetch failed: $e');
      }
    }

    // ── mbasic fetch for photo albums / carousels ──────────────────────────
    // Always try mbasic for non-video pages — it provides server-rendered HTML
    // with only the post content (no feed, ads, or recommendations).
    //
    // Auth cookies are passed when available (so friends-only posts work too)
    // but are NOT required — public posts are accessible without them.
    //
    // _mbasicUA (iOS Safari): mbasic.facebook.com serves basic HTML to mobile
    // UAs. App redirects (fb:// / intent://) only happen on www.facebook.com;
    // mbasic IS the app-free web version and never redirects to the native app.
    if (!isVideoPage) {
      try {
        // Build mbasic URL. For photo pages keep fbid/set (identify the album);
        // for all other pages use just the path — tracking params (rdid,
        // share_url, wtsid) can trigger unexpected redirects on mbasic.
        final parsed = Uri.tryParse(finalUrl);
        String mbasicUrl;
        if (parsed != null) {
          if (parsed.path.contains('/photo')) {
            const essential = {'fbid', 'set', 'id'};
            final qs = parsed.queryParametersAll.entries
                .where((e) => essential.contains(e.key))
                .expand((e) => e.value
                    .map((v) => '${e.key}=${Uri.encodeQueryComponent(v)}'))
                .join('&');
            mbasicUrl = 'https://mbasic.facebook.com${parsed.path}'
                '${qs.isNotEmpty ? '?$qs' : ''}';
          } else {
            mbasicUrl = 'https://mbasic.facebook.com${parsed.path}';
          }
        } else {
          mbasicUrl = finalUrl.replaceFirst(
              'https://www.facebook.com', 'https://mbasic.facebook.com');
        }
        debugPrint('[FB] mbasic carousel: $mbasicUrl');
        final mbasicHeaders = <String, String>{
          'User-Agent': _mbasicUA,
          // Referer: visiting mbasic from within mbasic (e.g. tapping a link)
          'Referer': 'https://mbasic.facebook.com/',
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'en-US,en;q=0.9',
          'Upgrade-Insecure-Requests': '1',
        };
        if (fbCookies != null) mbasicHeaders['Cookie'] = fbCookies;
        final mbasicDio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          followRedirects: true,
          maxRedirects: 8,
          headers: mbasicHeaders,
        ));
        final mbasicResp = await mbasicDio.get<String>(mbasicUrl);
        if (mbasicResp.statusCode == 200 && mbasicResp.data != null) {
          // Bail out if mbasic redirected us away (e.g. desktop UA on mbasic
          // can cause a redirect to www.facebook.com). The React SPA HTML would
          // poison allImages with hundreds of unrelated CDN image URLs.
          final respHost = mbasicResp.realUri?.host ?? '';
          if (!respHost.contains('mbasic.facebook.com')) {
            debugPrint('[FB] mbasic redirected to $respHost — skipping');
          } else {
            final mbasicHtml = mbasicResp.data!;

            // Phase 1 — Photo-link-anchored extraction.
            // In mbasic, every post photo is wrapped in an <a href="/photo.php?..."
            // or <a href="/photo?..."> link. Profile pictures, comment avatars, and
            // navigation elements are NOT linked to photo view pages, so this
            // pattern selects only actual post photos.
            final photoAnchorRe = RegExp(
              r'href="[^"]*(?:photo\.php|/photo[/?])[^"]*"',
              caseSensitive: false,
            );
            final imgRe = RegExp(
              r'<img[^>]+src="(https://[^"]*(?:scontent|fbcdn)[^"]*\.(?:jpg|jpeg|png|webp)[^"]*)"',
              caseSensitive: false,
            );
            for (final anchor in photoAnchorRe.allMatches(mbasicHtml)) {
              // Scan the 600 chars after each photo link for the <img src>.
              final end =
                  (anchor.end + 600).clamp(anchor.end, mbasicHtml.length);
              final slice = mbasicHtml.substring(anchor.end, end);
              final img = imgRe.firstMatch(slice);
              if (img != null) {
                final imgUrl = _unescape(img.group(1)!);
                if (!imgUrl.contains('/profile') &&
                    !imgUrl.contains('/rsrc') &&
                    !imgUrl.contains('/emoji') &&
                    !imgUrl.contains('static.xx.fbcdn') &&
                    !allImages.contains(imgUrl)) {
                  allImages.add(imgUrl);
                }
              }
            }

            // Phase 2 — Broad scan fallback (only when ≤1 image found so far).
            // Triggered when photo-link-anchored extraction finds nothing (e.g.
            // text posts with a single photo, or mbasic page has a non-standard
            // photo link format). With ≤1 image (the og:image is already in the
            // list), scanning mbasic CDN images adds the actual post photo(s).
            if (allImages.length <= 1) {
              for (final m in imgRe.allMatches(mbasicHtml)) {
                final imgUrl = _unescape(m.group(1)!);
                if (!imgUrl.contains('/profile') &&
                    !imgUrl.contains('/rsrc') &&
                    !imgUrl.contains('/emoji') &&
                    !imgUrl.contains('static.xx.fbcdn') &&
                    !allImages.contains(imgUrl)) {
                  allImages.add(imgUrl);
                }
              }
            }

            debugPrint('[FB] mbasic: ${allImages.length} images total');
          }
        }
      } catch (e) {
        debugPrint('[FB] mbasic fetch failed: $e');
      }
    }

    // ── Auth-based carousel supplement ────────────────────────────────────────
    // share/p/ and other share URL types sometimes deliver only 1 OG image
    // even for multi-photo carousels, and mbasic may not always resolve all
    // photos. When we have FB cookies and ≤1 image found so far on a non-video
    // page, do an authenticated desktop Chrome fetch to extract carousel images
    // from Facebook's React SPA JSON — it includes full_picture / uri for all
    // carousel nodes.
    if (!isVideoPage && allImages.length <= 1 && fbCookies != null) {
      debugPrint('[FB] Only ${allImages.length} image(s); trying auth carousel extract');
      try {
        await Future.delayed(Duration(milliseconds: 300 + Random().nextInt(400)));
        final carouselDio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          followRedirects: true,
          maxRedirects: 8,
          headers: {
            'User-Agent': _authUA,
            'Cookie': fbCookies,
            'sec-fetch-dest': 'document',
            'sec-fetch-mode': 'navigate',
            'sec-fetch-site': 'none',
            'sec-fetch-user': '?1',
            'sec-ch-ua':
                '"Chromium";v="124", "Google Chrome";v="124", "Not-A.Brand";v="99"',
            'sec-ch-ua-mobile': '?0',
            'sec-ch-ua-platform': '"Windows"',
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
            'Accept-Language': 'en-US,en;q=0.9',
            'Upgrade-Insecure-Requests': '1',
          },
        ));
        // Use the resolved canonical URL — share URLs redirect differently per UA.
        final resolvedUrl =
            finalUrl.isNotEmpty ? finalUrl.split('?').first : cleanUrl;
        final carouselResp = await carouselDio.get<String>(resolvedUrl);
        if (carouselResp.statusCode == 200 && carouselResp.data != null) {
          _extractCarouselImagesFromJson(carouselResp.data!, allImages);
          debugPrint('[FB] Auth carousel: ${allImages.length} images after extract');
        }
      } catch (e) {
        debugPrint('[FB] Auth carousel extract failed: $e');
      }
    }

    debugPrint(
        '[FB] video: ${realVideoUrl != null}, images: ${allImages.length}, user: $username');

    // ── Build items ───────────────────────────────────────────────────────
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final items = <MediaItem>[];

    if (realVideoUrl != null) {
      items.add(MediaItem(
        id: '0',
        mediaUrl: realVideoUrl,
        thumbnailUrl: allImages.isNotEmpty ? allImages.first : null,
        type: MediaItemType.video,
        username: username,
        itemIndex: 1,
        postTimestamp: now,
      ));
    }

    for (var i = 0; i < allImages.length; i++) {
      // Skip index 0 when a video is present — it's used as the thumbnail.
      if (realVideoUrl != null && i == 0) continue;
      // For video pages (reels, videos) the only downloadable item is the video.
      // Any extra images in allImages are keyframes, og:image thumbnails, or page
      // noise — not independent photos. Skip them to avoid showing garbage items.
      if (isVideoPage && realVideoUrl != null) continue;
      items.add(MediaItem(
        id: '${items.length}',
        mediaUrl: allImages[i],
        thumbnailUrl: allImages[i],
        type: MediaItemType.image,
        username: username,
        itemIndex: items.length + 1,
        postTimestamp: now,
      ));
    }

    // ── Private content fallback ──────────────────────────────────────────
    // If bot UA found nothing AND the user is logged in, retry with browser
    // UA + cookies. The browser response is a React SPA — no OG tags — so
    // we fall back to JSON pattern extraction only.
    if (items.isEmpty && fbCookies != null) {
      debugPrint('[FB] Bot UA found nothing; retrying with auth browser UA...');
      try {
        await Future.delayed(
            Duration(milliseconds: 500 + Random().nextInt(1500)));
        final authDio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          followRedirects: true,
          maxRedirects: 8,
          headers: {
            // Desktop UA — same reason as earlyAuthDio: avoids intent:// redirects.
            'User-Agent': _authUA,
            'Cookie': fbCookies,
            'sec-fetch-dest': 'document',
            'sec-fetch-mode': 'navigate',
            'sec-fetch-site': 'none',
            'sec-fetch-user': '?1',
            'sec-ch-ua':
                '"Chromium";v="124", "Google Chrome";v="124", "Not-A.Brand";v="99"',
            'sec-ch-ua-mobile': '?0',
            'sec-ch-ua-platform': '"Windows"',
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
            'Accept-Language': 'en-US,en;q=0.9',
            'Upgrade-Insecure-Requests': '1',
          },
        ));
        // Use resolved URL (not share URL) to avoid an extra redirect hop.
        final resolvedUrl =
            finalUrl.isNotEmpty ? finalUrl.split('?').first : cleanUrl;
        final authResp = await authDio.get<String>(resolvedUrl);
        if (authResp.statusCode == 200 && authResp.data != null) {
          final authHtml = authResp.data!;
          final authVideoUrl = _extractVideoUrlFromJson(authHtml);
          final authImages = <String>[];
          _extractCarouselImagesFromJson(authHtml, authImages);

          if (authVideoUrl != null) {
            items.add(MediaItem(
              id: '0',
              mediaUrl: authVideoUrl,
              thumbnailUrl: authImages.isNotEmpty ? authImages.first : null,
              type: MediaItemType.video,
              username: username,
              itemIndex: 1,
              postTimestamp: now,
            ));
          }
          for (var i = 0; i < authImages.length; i++) {
            if (authVideoUrl != null && i == 0) continue;
            items.add(MediaItem(
              id: '${items.length}',
              mediaUrl: authImages[i],
              thumbnailUrl: authImages[i],
              type: MediaItemType.image,
              username: username,
              itemIndex: items.length + 1,
              postTimestamp: now,
            ));
          }
          debugPrint(
              '[FB] Auth retry: video=${authVideoUrl != null}, images=${authImages.length}');
        }
      } catch (e) {
        debugPrint('[FB] Auth retry failed: $e');
      }
    }

    if (items.isEmpty) {
      throw Exception(
        'No downloadable media found.\n'
        'Facebook public posts require a direct post/video URL.\n'
        'Private content cannot be downloaded.',
      );
    }
    return items;
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Searches page HTML for the real video CDN URL from Facebook's embedded JSON.
  /// Facebook puts the actual MP4 URLs in JavaScript data blobs — these patterns
  /// cover Videos, Reels, and Watch posts.
  String? _extractVideoUrlFromJson(String html) {
    final patterns = [
      // Classic field names (web player, embed pages)
      RegExp(r'"browser_native_hd_url"\s*:\s*"([^"]+)"'),
      RegExp(r'"browser_native_sd_url"\s*:\s*"([^"]+)"'),
      RegExp(r'"playable_url_quality_hd"\s*:\s*"([^"]+)"'),
      RegExp(r'"playable_url"\s*:\s*"([^"]+)"'),
      RegExp(r'"hd_src"\s*:\s*"([^"]+)"'),
      RegExp(r'"sd_src"\s*:\s*"([^"]+)"'),
      RegExp(r'"video_url"\s*:\s*"([^"]+)"'),
      // Newer React SPA field names
      RegExp(r'"progressive_url"\s*:\s*"([^"]+)"'),
      RegExp(r'"video_full_url"\s*:\s*"([^"]+)"'),
      RegExp(r'"videoSrc"\s*:\s*"([^"]+)"'),
      // CDN URL patterns (catch-all for fbcdn video assets)
      RegExp(r'"(https://[^"]*\.fbcdn\.net[^"]*/[^"]*/[^"]*\.mp4[^"]*)"'),
      RegExp(r'"src"\s*:\s*"(https://[^"]*fbcdn\.net[^"]*\.mp4[^"]*)"'),
    ];

    for (final pattern in patterns) {
      final m = pattern.firstMatch(html);
      if (m != null) {
        final url = _unescape(m.group(1)!);
        if (url.startsWith('https://') &&
            (url.contains('fbcdn.net') || url.contains('fbcdn.com')) &&
            !url.contains('video/embed') &&
            !url.contains('.jpg') &&
            !url.contains('.png')) {
          final preview = pattern.pattern;
          debugPrint('[FB] Video URL found via: ${preview.substring(0, preview.length.clamp(0, 40))}');
          return url;
        }
      }
    }
    return null;
  }

  /// Extracts additional carousel/album image URLs from Facebook's embedded JSON.
  /// Searches multiple field names (`uri`, `src`, `url`) and both CDN domains.
  /// Only adds images not already in [existing].
  void _extractCarouselImagesFromJson(String html, List<String> existing) {
    final seen = existing.toSet();

    // Facebook uses various field names for image URIs in its JS payloads.
    // Both scontent (user photos) and fbcdn (general CDN) are valid image hosts.
    // Use [^"]+ (allows backslash) so JSON-encoded URLs like https:\/\/scontent...
    // are matched and then unescaped by _unescape(). Avoid [^"\\] which would
    // stop at the first \/ and never match anything in the page JSON.
    final patterns = [
      RegExp(
        r'"uri"\s*:\s*"(https[^"]*(?:scontent|fbcdn)[^"]*\.(?:jpg|jpeg|png|webp)[^"]*)"',
      ),
      RegExp(
        r'"src"\s*:\s*"(https[^"]*(?:scontent|fbcdn)[^"]*\.(?:jpg|jpeg|png|webp)[^"]*)"',
      ),
      RegExp(
        r'"url"\s*:\s*"(https[^"]*(?:scontent|fbcdn)[^"]*\.(?:jpg|jpeg|png|webp)[^"]*)"',
      ),
    ];

    for (final pattern in patterns) {
      for (final m in pattern.allMatches(html)) {
        final url = _unescape(m.group(1)!);
        if (!url.contains('/profile') &&
            !url.contains('/rsrc') &&
            !url.contains('/emoji') &&
            !url.contains('static.xx.fbcdn') &&
            seen.add(url)) {
          existing.add(url);
        }
      }
    }
  }

  /// Extracts a numeric video/reel ID from a Facebook URL.
  /// Handles three URL shapes:
  ///   /reel/<id>/                   → direct match
  ///   /videos/<id>/                 → direct match
  ///   /videos/中文標題/<id>/          → title-aware fallback
  ///   /posts/<id>/                  → direct match
  static String? _extractVideoIdFromUrl(String url) {
    final path = url.split('?').first;

    // Primary: numeric ID immediately after a video-type keyword
    final direct = RegExp(
      r'/(?:reel|videos|video|posts)/(\d{10,})',
      caseSensitive: false,
    ).firstMatch(path);
    if (direct != null) return direct.group(1);

    // Fallback: keyword, then any path segments (e.g. title), then a long numeric ID
    final withTitle = RegExp(
      r'/(?:reel|videos|video|posts)/[^?]+?/+(\d{10,})(?:/|$)',
      caseSensitive: false,
    ).firstMatch(path);
    return withTitle?.group(1);
  }

  /// Extracts a video URL from a `<video src="...">` tag in embed page HTML.
  String? _extractVideoTagSrc(String html) {
    final re = RegExp(r'<video[^>]+src="([^"]+\.mp4[^"]*)"', caseSensitive: false);
    final m = re.firstMatch(html);
    if (m == null) return null;
    final url = _unescape(m.group(1)!);
    return url.startsWith('https://') ? url : null;
  }

  String _unescape(String s) {
    // Decode all \uXXXX sequences (covers \u0026 → &, \u003F → ?, etc.)
    var result = s.replaceAllMapped(
      RegExp(r'\\u([0-9a-fA-F]{4})'),
      (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
    );
    return result.replaceAll(r'\/', '/');
  }
}
