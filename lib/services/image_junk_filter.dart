/// Shared "is this a junk image" heuristic for scrapers that pull `<img>`
/// elements out of arbitrary/generic HTML (the article scraper — including
/// Tumblr, which has no dedicated scraper — and Facebook) where there is no
/// structured JSON to whitelist real content from, unlike Instagram/Threads
/// which extract from known JSON fields and never need this heuristic.
///
/// Pure Dart, no Flutter UI imports, so it stays usable from any service and
/// unit-testable on its own.
library;

/// URL/attribute substrings that mark an image as chrome — avatar, icon,
/// logo, tracking pixel — rather than real post content. Case-insensitive.
/// Merges the generic article scraper's original list with Facebook's
/// (`/profile`, `/rsrc`, `/emoji`, `static.xx.fbcdn`) and Threads'
/// (`profilepic`, `profile_pic`) markers so every caller shares one list.
const junkMarkers = [
  'avatar', 'gravatar', 'logo', 'icon', 'favicon', 'sprite', 'emoji',
  'placeholder', 'spacer', 'blank.', '1x1', 'pixel', 'tracking', 'beacon',
  'loading', 'spinner', 'data:image',
  '/profile', '/rsrc', 'static.xx.fbcdn',
  'profilepic', 'profile_pic',
];

/// True if [url] (an image `src`/`href`, resolved or not) matches a junk
/// marker, or is an SVG — icons/logos are almost always SVG, real photo
/// content almost never is.
bool isJunkUrl(String url) {
  final lower = url.toLowerCase();
  if (lower.endsWith('.svg')) return true;
  return junkMarkers.any(lower.contains);
}

/// Alt-text markers unambiguous enough to flag an image as junk from `alt`
/// alone. The full [junkMarkers] list includes generic words — "icon",
/// "logo", "pixel", "sprite" — that show up in legitimate alt text on real
/// content, especially Tumblr art posts ("pixel art icon commission", "sprite
/// sheet WIP"), so matching the full list against `alt` silently drops real
/// images. These three are never legitimately part of real content alt text.
const _altOnlyJunkMarkers = ['avatar', 'gravatar', 'favicon'];

/// True if the image's URL OR any of its structural attributes (`class`,
/// `id`, `alt`) carry an avatar/icon marker. Element attributes are a signal
/// that URL-only filtering throws away — e.g. a Tumblr blog avatar commonly
/// renders as `class="avatar-image"` even when its CDN URL looks like any
/// other content image and gives no textual hint on its own. `alt` is
/// matched only against [_altOnlyJunkMarkers] (see its doc comment) — `class`
/// and `id` keep the full [junkMarkers] match since real content never
/// legitimately carries those in its class/id.
bool isJunkElement({String? url, String? className, String? id, String? alt}) {
  if (url != null && isJunkUrl(url)) return true;
  for (final attr in [className, id]) {
    if (attr == null) continue;
    final lower = attr.toLowerCase();
    if (junkMarkers.any(lower.contains)) return true;
  }
  if (alt != null) {
    final lower = alt.toLowerCase();
    if (_altOnlyJunkMarkers.any(lower.contains)) return true;
  }
  return false;
}
