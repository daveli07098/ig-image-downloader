/// Real Chrome-for-Android user agent (no "wv" WebView token) shared by every
/// in-app WebView in this app.
///
/// Android WebView normally includes "wv" in the User-Agent, which security
/// surfaces (Instagram's update_risky_contactpoint challenge, Automattic's
/// anti-bot gate, etc.) detect and reject/redirect-loop on. Using a real
/// Chrome Mobile UA makes the WebView look like a regular Chrome browser
/// session instead. See login_screen.dart's original WebView setup for the
/// investigation that established this.
const kRealChromeMobileUA =
    'Mozilla/5.0 (Linux; Android 14; SM-S9280) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/136.0.0.0 Mobile Safari/537.36';
