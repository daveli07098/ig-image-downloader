/// Lower-cased substrings that mark a page as showing a JS-based anti-bot
/// challenge rather than real content — e.g. Automattic's hashcash-based
/// `/__challenge` gate seen on Tumblr, whose 403 body's title reads
/// "Checking your browser... Javascript required" and which posts an
/// `X-Hashcash-Solution` header once solved by the page's own JS.
///
/// Pure Dart, no Flutter imports, so it can be shared by both the plain-Dio
/// service layer ([GenericArticleDownloaderService]) and the WebView fetcher
/// without pulling UI code into the service layer.
///
/// Split into two tiers so an ordinary 200 page can't be misclassified as a
/// challenge just because it has innocuous `<noscript>` boilerplate
/// containing the phrase "javascript required":
///   * STRONG — conclusive on their own (challenge-specific markup/cookie
///     names: the `/__challenge` endpoint/element id, the
///     `X-Hashcash-Solution` header, the `hashcash` mechanism name, the
///     `_hcc` cookie).
///   * WEAK — only meaningful alongside a 403, since the copy alone is common
///     `<noscript>` boilerplate on ordinary sites.
const jsChallengeStrongSignals = <String>[
  '__challenge',
  'x-hashcash-solution',
  'hashcash',
  '_hcc',
];

const jsChallengeWeakSignals = <String>[
  'checking your browser',
  'javascript required',
];

/// True when [html] still shows a JS anti-bot challenge (title copy or the
/// `#__challenge` element) rather than the real page content.
///
/// [wasForbidden] must reflect whether the response that produced [html] was
/// an HTTP 403 — WEAK signals are only trusted in that context; STRONG
/// signals are conclusive regardless of status code.
bool looksLikeJsChallenge(String html, {required bool wasForbidden}) {
  final lower = html.toLowerCase();
  if (jsChallengeStrongSignals.any(lower.contains)) return true;
  return wasForbidden && jsChallengeWeakSignals.any(lower.contains);
}
