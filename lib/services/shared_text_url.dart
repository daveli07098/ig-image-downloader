// Extracts a usable URL out of arbitrary shared/pasted text.
//
// Share sheets (LIHKG, Tumblr, Facebook, ...) commonly send the post title
// followed by the link on the same or a later line, e.g.
//   `baby梓有無資格做新一代連登女神啊？ https://lih.kg/4158154`
// A naive `startsWith('http')`/`contains('instagram.com')` check misses
// this shape entirely, so callers must run shared/pasted text through this
// helper first rather than validating the raw text directly.

import 'facebook_downloader_service.dart';
import 'ig_url_parser.dart';
import 'lihkg_downloader_service.dart';
import 'threads_downloader_service.dart';
import 'x_downloader_service.dart';

/// Regex for a bare `http(s)://` URL run — matches greedily up to the next
/// whitespace character, trailing punctuation is trimmed off afterwards by
/// [_stripTrailingPunctuation] so it doesn't need to be excluded here.
final RegExp _urlPattern = RegExp(r'https?://\S+', caseSensitive: false);

// Trailing characters that commonly follow a pasted/shared link but are not
// part of it (sentence punctuation, closing brackets/quotes, CJK
// punctuation). A trailing `/` is intentionally NOT included here — it's a
// legitimate (and common) URL terminator.
const String _trailingPunctuation =
    '.,;:!?)]}"\'>' '。，、！？）》」』】';

/// Strips characters in [_trailingPunctuation] off the end of [url],
/// repeatedly (e.g. a URL followed by `.)` needs both removed).
String _stripTrailingPunctuation(String url) {
  var end = url.length;
  while (end > 0 && _trailingPunctuation.contains(url[end - 1])) {
    end--;
  }
  return url.substring(0, end);
}

/// Finds the first `http://`/`https://` URL anywhere in [text] (including
/// across multiple lines), stripping common trailing punctuation that isn't
/// actually part of the link.
///
/// When [text] contains several URLs, the first one recognised by a known
/// platform matcher wins (Instagram, X/Twitter, Threads, Facebook, LIHKG);
/// otherwise the first URL found is returned. Pass [isKnownPlatform] to use
/// a caller-supplied matcher instead of the built-in platform list (useful
/// if importing all the platform services isn't desired at a call site).
///
/// Returns null when [text] contains no URL at all.
String? extractFirstUrl(String text, {bool Function(String)? isKnownPlatform}) {
  final matches = _urlPattern
      .allMatches(text)
      .map((m) => _stripTrailingPunctuation(m.group(0)!))
      .where((u) => u.isNotEmpty)
      .toList();
  if (matches.isEmpty) return null;

  final matcher = isKnownPlatform ?? _isKnownPlatformUrl;
  for (final url in matches) {
    if (matcher(url)) return url;
  }
  return matches.first;
}

bool _isKnownPlatformUrl(String url) {
  return IgUrlParser.isInstagramUrl(url) ||
      XDownloaderService.isXUrl(url) ||
      ThreadsDownloaderService.isThreadsUrl(url) ||
      FacebookDownloaderService.isFacebookUrl(url) ||
      LihkgDownloaderService.isLihkgUrl(url);
}
