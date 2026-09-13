import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import '../models/media_item.dart';
import 'image_junk_filter.dart';

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

  /// Extracts a numeric post ID from a `/posts/<id>/`, `/permalink/<id>/`, or
  /// `permalink.php?story_fbid=<id>` URL — the URL shapes whose story JSON is
  /// scoped and parsed by [_parseStoryFromDataSjs]. Returns null for every
  /// other shape (reel/videos/share/watch), which keep the legacy og:type +
  /// regex pipeline below untouched.
  static String? _extractPostIdForStory(String url) {
    final postsMatch = RegExp(r'/posts/(\d+)').firstMatch(url);
    if (postsMatch != null) return postsMatch.group(1);
    final permalinkMatch = RegExp(r'/permalink/(\d+)').firstMatch(url);
    if (permalinkMatch != null) return permalinkMatch.group(1);
    final storyFbid = Uri.tryParse(url)?.queryParameters['story_fbid'];
    if (storyFbid != null && RegExp(r'^\d+$').hasMatch(storyFbid)) {
      return storyFbid;
    }
    return null;
  }

  /// Path segments that are never a usable display name — URL-shape keywords
  /// (`posts`, `photo`, …) AND, since 2026-09-14, the two profile-URL shapes
  /// that otherwise leak a wrong "username": `facebook.com/people/<Name>/
  /// <numericId>/` (blindly taking the LAST segment used to yield the
  /// numeric id, not `<Name>`) and `facebook.com/profile.php?id=…` (yields
  /// the literal string `profile.php`, the only path segment it has).
  static const _usernameUrlSkipSegments = {
    'posts', 'permalink', 'photo', 'photos', 'videos', 'video',
    'share', 'r', 'reel', 'reels', 'watch', 'www.facebook.com',
    'profile.php', 'people',
  };

  /// First non-numeric, non-keyword path segment of [url] — shared by the
  /// `og:url` fallback and, since 2026-09-14, [_usernameFromStory]'s
  /// `actors[0].url` handling (previously took the LAST segment
  /// unconditionally, which broke on `/people/<Name>/<numericId>/` and
  /// `/profile.php?id=…` shapes — see [_usernameUrlSkipSegments]).
  static String? _firstUsableUrlSegment(String? url) {
    if (url == null) return null;
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    for (final seg in uri.pathSegments) {
      if (seg.isEmpty) continue;
      if (RegExp(r'^\d+$').hasMatch(seg)) continue;
      if (_usernameUrlSkipSegments.contains(seg.toLowerCase())) continue;
      return seg;
    }
    return null;
  }

  /// Fallback username for a story-JSON post: the non-numeric, non-keyword
  /// path segment of `og:url` (e.g. `HKACGer` from
  /// `facebook.com/HKACGer/posts/<id>/`). Used only when the post's own
  /// `actors[0]` (url/name) is unavailable.
  static String? _nonNumericOgUrlSegment(String? ogUrl) =>
      _firstUsableUrlSegment(ogUrl);

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
        if (!isJunkUrl(content) && !ogImages.contains(content)) {
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

    // ── /posts/ (and /permalink/, story_fbid) story-JSON extraction ────────
    // Verified WRONG on 2026-09-14: og:type identifies videos for reels but
    // NOT for /posts/ URLs — Facebook serves og:type=video.other to the bot
    // UA for plain photo albums, and the page's unscoped video regex then
    // matches an unrelated Reels-rail video ~1 MB away in the same page,
    // hiding the whole photo album behind a wrong video. For these URL
    // shapes the only reliable source of truth is the post's own story JSON
    // (`post_id` + `attachments`), which lives in the authenticated desktop
    // page — bot-UA HTML has just OG meta tags, and mbasic is login-walled
    // even with a valid cookie as of 2026-09-14, so it can no longer
    // enumerate album photos either.
    final postId = _extractPostIdForStory(finalUrl) ??
        _extractPostIdForStory(url) ??
        _extractPostIdForStory(cleanUrl);
    _StoryData? story;
    if (postId != null && fbCookies != null) {
      try {
        // Small random delay before the authenticated fetch — breaks the
        // pattern of back-to-back requests with millisecond precision, a
        // reliable automation-detection signal.
        await Future.delayed(
            Duration(milliseconds: 500 + Random().nextInt(1500)));
        final resolvedUrl =
            finalUrl.isNotEmpty ? finalUrl.split('?').first : cleanUrl;
        final storyAuthHtml =
            await _fetchAuthenticatedHtml(resolvedUrl, fbCookies);
        if (storyAuthHtml != null) {
          story = _parseStoryFromDataSjs(storyAuthHtml, postId);
        }
      } catch (e) {
        debugPrint('[FB] story parse fetch failed: $e');
      }
    }

    if (story != null) {
      final storyItems = _buildItemsFromStory(story, ogUrl, allImages);
      if (storyItems.isNotEmpty) {
        debugPrint('[FB] story parse: ${story.photos.length} photos, '
            '${story.video != null ? 1 : 0} videos '
            '(page=${storyItems.first.username})');
        debugPrint('[FB] SERVED BY: story-json (post=$postId)');
        return storyItems;
      }
      debugPrint(
          '[FB] story parse yielded no usable items — falling back to legacy pipeline');
    }

    // Detect video pages by og:type OR URL patterns. Facebook reel URLs often
    // omit og:type=video when served to the facebookexternalhit bot UA.
    // EXCEPTION verified wrong on 2026-09-14: for /posts/ (and /permalink/,
    // story_fbid) URLs og:type must never be trusted when the story JSON
    // actually ran and resolved this post (see above) — that JSON is the
    // post's own attachments and is authoritative. The switch is on
    // `story != null` (the parse ACTUALLY FOUND this post), not merely
    // `postId != null` — corrected 2026-09-14 after device testing showed a
    // genuinely public video shared as `/posts/<id>/` with NO session (so
    // the story JSON never ran) was silently never classified as a video,
    // losing the bot-UA-only `/video/embed`+plugin probes that used to find
    // it. When the story parse didn't run (no session) or ran but couldn't
    // find this post's node at all, fall back to the legacy og:type/URL
    // logic — the photo-post protection is unaffected: when the story DID
    // run and found only photos, `story.video == null` still forces false.
    final isVideoPage = story != null
        ? story.video != null
        : (ogType != null && ogType!.startsWith('video')) ||
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
    //
    // `postId == null` guard added 2026-09-14 (code review flagged this site
    // was missed alongside the other two unscoped-regex call sites already
    // guarded below): this is an unscoped, page-wide regex — never safe to
    // run for /posts/ URLs regardless of how isVideoPage ended up true (og:type
    // fallback OR a story-confirmed Video attachment whose URL
    // [_findVideoUrlInNode] simply couldn't resolve). The embed/plugin probes
    // just below are the correct /posts/-safe fallback instead — they hit
    // small, video-id-scoped endpoints, not this page's full HTML.
    if (isVideoPage && postId == null) {
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
    //
    // `postId == null` guard added 2026-09-14: this is the exact unscoped
    // regex that caused the original bug for /posts/ URLs (matched an
    // unrelated Reels-rail video ~1 MB away from the actual post in the same
    // SPA HTML). For /posts/ URLs, [_parseStoryFromDataSjs] above already
    // tried the scoped, post_id-anchored equivalent — if that came up empty,
    // falling back to this unscoped search would silently reintroduce the
    // bug rather than genuinely finding this post's video.
    if (fbCookies != null && isVideoPage && realVideoUrl == null && postId == null) {
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
    // VERIFIED WRONG on 2026-09-14 for `/posts/<id>/` pages specifically:
    // mbasic now redirects even an authenticated (valid-cookie) request to
    // `m.facebook.com/login/?next=…` for these URLs — it can no longer
    // enumerate a `/posts/` album's photos at all, cookie or not. This block
    // is left in place (still correct for share/photo/set-style URLs where
    // mbasic does work, and its own host-redirect check already bails out
    // cleanly on the login gate) but for `/posts/` pages the story-JSON path
    // above is now the real source of truth — this is just the safety net
    // when that path is unavailable (no session) or came up empty.
    //
    // _mbasicUA (iOS Safari): mbasic.facebook.com serves basic HTML to mobile
    // UAs. App redirects (fb:// / intent://) only happen on www.facebook.com;
    // mbasic IS the app-free web version and never redirects to the native app.
    //
    // phase1Count tracks how many images Phase 1 (photo-link-anchored scan)
    // found. When it stays at 0 the mbasic page had no per-photo <a> links
    // (e.g. a /posts/ view) so we cannot trust Phase 2 to be complete; the
    // auth carousel supplement is then triggered regardless of image count.
    var phase1Count = 0;
    // Run photo extraction for genuine photo pages AND for "video" pages where
    // no real video URL was found: Facebook mislabels many multi-photo albums
    // as og:type=video.other, which sets isVideoPage but yields no MP4 — those
    // are actually photo albums and must go through the carousel extractor.
    // (This og:type mislabeling applies whenever the story JSON DIDN'T run
    // or didn't find this post — no session, or the parse came up empty. For
    // `/posts/` URLs where the story JSON DID find the post, isVideoPage
    // above is derived from the post's own attachments instead, never
    // og:type — corrected 2026-09-14.)
    final treatAsPhotoPage = !isVideoPage || realVideoUrl == null;
    if (treatAsPhotoPage) {
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
                if (!isJunkUrl(imgUrl) && !allImages.contains(imgUrl)) {
                  allImages.add(imgUrl);
                  phase1Count++;
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
                if (!isJunkUrl(imgUrl) && !allImages.contains(imgUrl)) {
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
    // photos. Run an authenticated desktop Chrome fetch to extract carousel
    // images from Facebook's React SPA JSON when:
    //
    //   • phase1Count == 0  — mbasic served a /posts/ page with no individual
    //     <a href="/photo…"> links, so Phase 2 only found the first inline photo;
    //     we need auth to discover the rest regardless of total count.
    //   • allImages.length < 5  — safety net for small/partial result sets.
    //
    // The call passes the first confirmed image's _nc_cat CDN bucket ID so the
    // extractor only accepts images in the same bucket (same post/album).
    final needsAuthCarousel = treatAsPhotoPage && fbCookies != null &&
        (phase1Count == 0 || allImages.length < 5);
    if (needsAuthCarousel) {
      debugPrint('[FB] phase1=$phase1Count imgs=${allImages.length}; trying auth carousel extract');
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
          final before = allImages.length;
          // Strict pass first: prefer images sharing the reference image's
          // _nc_cat CDN bucket, which filters out unrelated posts on the page.
          final refNcCat = allImages.isNotEmpty
              ? _extractNcCat(allImages.first)
              : null;
          _extractCarouselImagesFromJson(
              carouselResp.data!, allImages, refNcCat: refNcCat);

          // Relaxed fallback: _nc_cat is a per-image CDN edge bucket, NOT a
          // reliable album identifier — sibling photos in the same album are
          // often served from different buckets and the strict pass drops them,
          // collapsing a multi-photo post to just its cover. If the strict pass
          // recovered nothing new, rescan without the bucket filter so the rest
          // of the album is captured (the path already targets the canonical
          // post permalink, so unrelated images are unlikely here).
          if (refNcCat != null && allImages.length == before) {
            debugPrint('[FB] Auth carousel: strict _nc_cat pass found nothing new — relaxing filter');
            _extractCarouselImagesFromJson(carouselResp.data!, allImages);
          }
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
          // postId == null guard: same reason as the earlier auth-fetch-for-
          // video block — an unscoped regex over the full SPA HTML must never
          // run for /posts/ URLs (that's the exact 2026-09-14 bug mechanism).
          final authVideoUrl =
              postId == null ? _extractVideoUrlFromJson(authHtml) : null;
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

  // ── Story-JSON parsing (/posts/, /permalink/, story_fbid URLs) ──────────
  //
  // Field-verified 2026-09-14 against two real authenticated post-page dumps:
  // the logged-in `www.facebook.com` desktop page embeds the full post JSON
  // in `<script type="application/json" data-sjs>` blocks (204 in one dump),
  // ALL valid JSON. Exactly one node per post carries `post_id == <id>` AND a
  // non-empty `attachments` list (it can appear twice — `result/data/node_v2`
  // and its nested `comet_sections/content/story` — with identical data; both
  // are walked and the first to actually yield media wins). The same page
  // routinely also contains OTHER posts' story data (news-feed rail) and
  // unrelated videos (Reels rail) — scoping to the exact post_id is mandatory,
  // never "the first attachments/all_subattachments/progressive_url on the
  // page".

  /// Fetches [url] with the authenticated desktop Chrome UA + [cookies] and
  /// returns the response body, or null on any non-200/failure. Shared by the
  /// story-JSON fetch above — desktop UA is required (not mobile) because
  /// Facebook 302s mobile UAs on authenticated requests to `intent://`/`fb://`
  /// deep links, which Dio cannot follow.
  Future<String?> _fetchAuthenticatedHtml(String url, String cookies) async {
    final authDio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      followRedirects: true,
      maxRedirects: 8,
      headers: {
        'User-Agent': _authUA,
        'Cookie': cookies,
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
    final resp = await authDio.get<String>(url);
    if (resp.statusCode == 200 && resp.data != null) return resp.data;
    return null;
  }

  /// Parses [html] for the story JSON of [postId]. Pre-filters `data-sjs`
  /// blocks with a cheap `contains()` check on the raw text BEFORE
  /// `jsonDecode` — a real authenticated page is 4+ MB with 200+ such blocks,
  /// and decoding all of them on a phone is wasteful; field-verified only the
  /// ONE block actually containing this post decodes to anything useful.
  /// Returns null when no block yields a node with usable media (never a
  /// guess from a structurally-similar-but-wrong node).
  ///
  /// Exercised indirectly by the unit test (via the public
  /// [parseStoryForTesting]) against `test/fixtures/facebook_post_story.html`.
  _StoryData? _parseStoryFromDataSjs(String html, String postId) {
    final needle = '"post_id":"$postId"';
    final scriptRe = RegExp(
      r'<script type="application/json"[^>]*data-sjs[^>]*>([\s\S]*?)</script>',
      caseSensitive: false,
    );
    for (final m in scriptRe.allMatches(html)) {
      final raw = m.group(1);
      if (raw == null || !raw.contains(needle)) continue;
      dynamic data;
      try {
        data = jsonDecode(raw);
      } catch (e) {
        debugPrint(
            '[FB] story parse: data-sjs block matched post_id but failed to decode: $e');
        continue;
      }
      for (final node in _findStoryNodes(data, postId)) {
        final result = _storyDataFromNode(node, html);
        if (result != null) return result;
      }
    }
    return null;
  }

  /// Recursively walks a decoded data-sjs JSON tree yielding every Map whose
  /// `post_id` equals [postId] AND carries a non-empty `attachments` list —
  /// a bare reference (e.g. inside a permalink string's parent object) that
  /// merely echoes the post_id without attachments is never a candidate.
  Iterable<Map<String, dynamic>> _findStoryNodes(
      dynamic node, String postId) sync* {
    if (node is Map) {
      if (node['post_id'] == postId) {
        final atts = node['attachments'];
        if (atts is List && atts.isNotEmpty) {
          yield node.cast<String, dynamic>();
        }
      }
      for (final v in node.values) {
        yield* _findStoryNodes(v, postId);
      }
    } else if (node is List) {
      for (final v in node) {
        yield* _findStoryNodes(v, postId);
      }
    }
  }

  /// Builds [_StoryData] (photos, video, actor, creation_time) from a single
  /// story node's `attachments`. Handles both shapes field-verified 2026-09-14:
  ///   - album: `attachments[].styles.attachment.all_subattachments.nodes[].media`
  ///   - single photo/video: `attachments[].media` and/or
  ///     `attachments[].styles.attachment.media` (no fixture for this shape —
  ///     handled defensively).
  /// Returns null when nothing usable was found (photos empty AND no video),
  /// so [_parseStoryFromDataSjs] tries the next candidate node instead of
  /// returning an empty success.
  _StoryData? _storyDataFromNode(Map<String, dynamic> node, String rawHtml) {
    final photos = <_StoryPhoto>[];
    final seenFbids = <String>{};
    _StoryVideo? video;

    void merge(_ConsumedMedia? r) {
      if (r == null) return;
      if (r.photo != null) photos.add(r.photo!);
      video ??= r.video;
    }

    final actors = node['actors'];
    String? actorUrl, actorName;
    if (actors is List && actors.isNotEmpty && actors.first is Map) {
      final actor = actors.first as Map;
      actorUrl = actor['url'] as String?;
      actorName = actor['name'] as String?;
    }
    final creationTime = node['creation_time'];

    final attachments = node['attachments'];
    if (attachments is List) {
      for (final attRaw in attachments) {
        if (attRaw is! Map) continue;

        // Album case FIRST: `all_subattachments.nodes[].media` carries the
        // real per-photo data (viewer_image/image); the top-level
        // `attachments[].media` on an album is just a bare
        // `{__typename, id}` reference to photo 1 with NO image data at all
        // (field-verified 2026-09-14) — consuming that first would win the
        // fbid-dedup race and silently downgrade photo 1 to the lookaside
        // fallback even though the real URL was sitting right there in
        // all_subattachments. Processing the fuller source first means
        // dedup-by-fbid always keeps the best data for a given photo.
        final styles = attRaw['styles'];
        if (styles is Map) {
          debugPrint(
              '[FB] story parse: attachment styles.__typename=${styles['__typename']}');
          final styleAttachment = styles['attachment'];
          if (styleAttachment is Map) {
            final subattachments = styleAttachment['all_subattachments'];
            if (subattachments is Map) {
              final nodes = subattachments['nodes'];
              final count = subattachments['count'];
              if (nodes is List) {
                debugPrint('[FB] story parse: all_subattachments '
                    'count=$count nodes=${nodes.length}');
                if (count is int && count != nodes.length) {
                  debugPrint(
                      '[FB] story parse: all_subattachments count=$count but '
                      'nodes.length=${nodes.length} — Facebook truncated the '
                      'list; no pagination implemented');
                }
                for (final subNode in nodes) {
                  if (subNode is Map) {
                    merge(_consumeMedia(
                        subNode['media'], seenFbids, rawHtml));
                  }
                }
              }
            }
            // Single photo/video posts (no album wrapper) can carry media
            // directly here.
            merge(_consumeMedia(
                styleAttachment['media'], seenFbids, rawHtml));
          }
        }

        // Fallback / single photo/video posts: media directly on the
        // attachment. Dedup by fbid means this is a no-op whenever the
        // album branch above already resolved the same fbid with real data.
        merge(_consumeMedia(attRaw['media'], seenFbids, rawHtml));
      }
    }

    if (photos.isEmpty && video == null) return null;
    return _StoryData(
      photos: photos,
      video: video,
      actorUrl: actorUrl,
      actorName: actorName,
      creationTime: creationTime is int ? creationTime : null,
    );
  }

  /// Classifies a single `media` node as a photo (dedup'd by fbid) or a
  /// video, or ignores it (anything else — e.g. null, or a typename we don't
  /// handle). Photo URL preference: `viewer_image.uri` (full-size rendition,
  /// field-verified 1300×1650 – 1536×2048) → `image.uri` (~590px thumbnail)
  /// → the anonymous lookaside fallback by fbid (field-verified to return a
  /// real JPEG with no session, e.g. 1300×1650 195KB).
  _ConsumedMedia? _consumeMedia(
      dynamic media, Set<String> seenPhotoFbids, String rawHtml) {
    if (media is! Map) return null;
    final typename = media['__typename'] as String?;
    final id = media['id'] as String?;
    if (id == null) return null;

    if (typename == 'Photo') {
      if (!seenPhotoFbids.add(id)) return null; // dedupe by fbid
      final viewerUri = (media['viewer_image'] as Map?)?['uri'] as String?;
      final imageUri = (media['image'] as Map?)?['uri'] as String?;
      final rawUrl = viewerUri ?? imageUri;
      final url = rawUrl != null
          ? _unescape(rawUrl)
          : 'https://lookaside.fbsbx.com/lookaside/crawler/media/?media_id=$id';
      return _ConsumedMedia(photo: _StoryPhoto(id, url));
    }

    if (typename == 'Video') {
      final url = _findVideoUrlInNode(media, rawHtml, id);
      return _ConsumedMedia(video: _StoryVideo(id, url));
    }

    return null;
  }

  /// Finds the real CDN video URL for a Video attachment's [videoId]. There
  /// is no /posts/ video fixture (field notes, 2026-09-14) — this is
  /// deliberately defensive and NEVER falls back to an unscoped page-wide
  /// search (that's the exact bug this whole story-JSON path exists to fix):
  ///   1. Known field names (`playable_url`, `browser_native_hd_url`,
  ///      `browser_native_sd_url`, `progressive_url`) within [mediaNode]'s own
  ///      JSON subtree — already scoped, since [mediaNode] came from this
  ///      post's attachments.
  ///   2. A bounded window (±2000 chars) around each `"id":"<videoId>"`
  ///      occurrence in [rawHtml] — still scoped to this specific video's id,
  ///      unlike a page-wide regex.
  String? _findVideoUrlInNode(Map mediaNode, String rawHtml, String videoId) {
    final direct = _searchVideoUrlKeys(mediaNode);
    if (direct != null) return direct;

    final needle = '"id":"$videoId"';
    var searchFrom = 0;
    while (true) {
      final idx = rawHtml.indexOf(needle, searchFrom);
      if (idx == -1) break;
      final start = (idx - 2000).clamp(0, rawHtml.length);
      final end = (idx + 2000).clamp(0, rawHtml.length);
      final found = _extractVideoUrlFromJson(rawHtml.substring(start, end));
      if (found != null) return found;
      searchFrom = idx + needle.length;
    }
    return null;
  }

  /// Recursively searches [obj] for one of the known video-URL field names.
  static const _videoUrlKeys = [
    'playable_url',
    'browser_native_hd_url',
    'browser_native_sd_url',
    'progressive_url',
  ];
  String? _searchVideoUrlKeys(dynamic obj) {
    if (obj is Map) {
      for (final k in _videoUrlKeys) {
        final v = obj[k];
        if (v is String && v.isNotEmpty) return _unescape(v);
      }
      for (final v in obj.values) {
        final found = _searchVideoUrlKeys(v);
        if (found != null) return found;
      }
    } else if (obj is List) {
      for (final v in obj) {
        final found = _searchVideoUrlKeys(v);
        if (found != null) return found;
      }
    }
    return null;
  }

  /// Builds the final [MediaItem] list from parsed [_StoryData]. Username:
  /// `actors[0].url` last path segment → `actors[0].name` → the non-numeric
  /// `og:url` path segment → `'facebook'` (never [_usernameFromUrl] — that
  /// fallback is for the legacy pipeline only). Date: `creation_time` (unix
  /// seconds) → now.
  ///
  /// When the story parse yielded items, the `og:image` seed is deliberately
  /// NOT added on top — for /posts/ pages og:image is photo 1 again (the
  /// lookaside crawler URL for the same fbid), served under a different URL.
  List<MediaItem> _buildItemsFromStory(
      _StoryData story, String? ogUrl, List<String> ogImages) {
    final username = _usernameFromStory(story, ogUrl);
    final timestamp =
        story.creationTime ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    final items = <MediaItem>[];

    if (story.video != null) {
      if (story.video!.url != null) {
        items.add(MediaItem(
          id: '0',
          mediaUrl: story.video!.url!,
          thumbnailUrl: story.photos.isNotEmpty
              ? story.photos.first.url
              : (ogImages.isNotEmpty ? ogImages.first : null),
          type: MediaItemType.video,
          username: username,
          itemIndex: 1,
          postTimestamp: timestamp,
        ));
      } else {
        debugPrint('[FB] story parse: Video attachment ${story.video!.id} '
            'found but no resolvable URL — omitting');
      }
    }

    for (final photo in story.photos) {
      items.add(MediaItem(
        id: '${items.length}',
        mediaUrl: photo.url,
        thumbnailUrl: photo.url,
        type: MediaItemType.image,
        username: username,
        itemIndex: items.length + 1,
        postTimestamp: timestamp,
      ));
    }
    return items;
  }

  static String _usernameFromStory(_StoryData story, String? ogUrl) {
    // Was: blindly take the LAST path segment of actors[0].url. Verified
    // wrong on 2026-09-14 (code review): `facebook.com/people/<Name>/
    // <numericId>/` yielded the numeric id, and `facebook.com/profile.php?
    // id=…` yielded the literal `profile.php` — both real profile URL shapes
    // Facebook uses when a page has no vanity username. Reuses
    // [_firstUsableUrlSegment] (skips numeric segments and both of those
    // shapes) instead, matching the `og:url` fallback's logic.
    final actorSeg = _firstUsableUrlSegment(story.actorUrl);
    if (actorSeg != null) return actorSeg;
    if (story.actorName != null && story.actorName!.isNotEmpty) {
      return story.actorName!;
    }
    final ogSeg = _nonNumericOgUrlSegment(ogUrl);
    if (ogSeg != null) return ogSeg;
    return 'facebook';
  }

  /// Test-only passthrough returning the final [MediaItem] list, mirroring
  /// the shape tests assert on (mediaUrl/username/type/postTimestamp)
  /// without needing the full `fetchItems` network pipeline.
  @visibleForTesting
  List<MediaItem> parseStoryForTesting(String html, String postId,
      {String? ogUrl}) {
    final story = _parseStoryFromDataSjs(html, postId);
    if (story == null) return [];
    return _buildItemsFromStory(story, ogUrl, const []);
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
  ///
  /// [refNcCat] — when provided, only images whose `_nc_cat` CDN bucket matches
  /// this value are accepted. This filters out images from other posts that may
  /// appear in the same SPA page JSON. Images without the parameter are accepted
  /// unconditionally (some older URLs omit it).
  void _extractCarouselImagesFromJson(String html, List<String> existing,
      {String? refNcCat}) {
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
        if (!isJunkUrl(url) &&
            _ncCatMatches(url, refNcCat) &&
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

  /// Returns the `_nc_cat` CDN bucket parameter from a Facebook image URL.
  /// All photos in the same Facebook post/album share the same bucket ID —
  /// using it as a filter rejects images from unrelated posts on the same page.
  static String? _extractNcCat(String url) =>
      Uri.tryParse(url)?.queryParameters['_nc_cat'];

  /// Returns true when [url] belongs to the same CDN bucket as [refNcCat].
  /// If either side is null (parameter absent) the image is accepted so that
  /// older URLs without the parameter are never incorrectly rejected.
  static bool _ncCatMatches(String url, String? refNcCat) {
    if (refNcCat == null) return true;
    final cat = Uri.tryParse(url)?.queryParameters['_nc_cat'];
    return cat == null || cat == refNcCat;
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

// ── Story-JSON data model ──────────────────────────────────────────────────
// Private to this file — tests reach these only through
// FacebookDownloaderService.parseStoryForTesting, which returns MediaItems.

class _StoryPhoto {
  final String fbid;
  final String url;
  _StoryPhoto(this.fbid, this.url);
}

class _StoryVideo {
  final String id;
  final String? url;
  _StoryVideo(this.id, this.url);
}

class _StoryData {
  final List<_StoryPhoto> photos;
  final _StoryVideo? video;
  final String? actorUrl;
  final String? actorName;
  final int? creationTime;
  _StoryData({
    required this.photos,
    this.video,
    this.actorUrl,
    this.actorName,
    this.creationTime,
  });
}

/// Result of classifying a single `media` node — at most one of [photo]/
/// [video] is non-null.
class _ConsumedMedia {
  final _StoryPhoto? photo;
  final _StoryVideo? video;
  _ConsumedMedia({this.photo, this.video});
}
