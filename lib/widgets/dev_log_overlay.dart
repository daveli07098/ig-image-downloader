import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/dev_logger.dart';

/// Debug-only floating log overlay.
///
/// Wraps the app content with a semi-transparent slide-up panel that shows all
/// [debugPrint] output captured by [DevLogger].  Completely absent in release
/// builds (kDebugMode guard).
///
/// Usage — add via MaterialApp.builder:
/// ```dart
/// builder: (context, child) => DevLogOverlay(child: child ?? const SizedBox()),
/// ```
class DevLogOverlay extends StatefulWidget {
  const DevLogOverlay({super.key, required this.child});

  final Widget child;

  @override
  State<DevLogOverlay> createState() => _DevLogOverlayState();
}

class _DevLogOverlayState extends State<DevLogOverlay> {
  bool _open = false;
  final ScrollController _scroll = ScrollController();
  final _logger = DevLogger.instance;

  @override
  void initState() {
    super.initState();
    _logger.addListener(_onNewLog);
  }

  @override
  void dispose() {
    _logger.removeListener(_onNewLog);
    _scroll.dispose();
    super.dispose();
  }

  void _onNewLog() {
    if (!mounted) return;
    // Auto-open when a new fetch session starts (requested by HomeScreen).
    if (_logger.openRequested) {
      _logger.openRequested = false;
      _open = true;
    }
    setState(() {});
    if (_open) _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return widget.child;

    return LayoutBuilder(
      builder: (context, constraints) {
        final panelH = constraints.maxHeight * 0.6;
        final entries = _logger.entries;

        return Stack(
          children: [
            widget.child,

            // ── Slide-up log panel ──────────────────────────────────────
            AnimatedPositioned(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOut,
              left: 0,
              right: 0,
              bottom: _open ? 0 : -panelH,
              height: panelH,
              child: Material(
                elevation: 20,
                color: const Color(0xED0D0D1A), // near-black, slightly transparent
                child: Column(
                  children: [
                    // ── Header bar ────────────────────────────────────────
                    Container(
                      color: const Color(0xFF13132A),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: Row(
                        children: [
                          const Icon(Icons.bug_report,
                              color: Colors.greenAccent, size: 16),
                          const SizedBox(width: 6),
                          Text(
                            'Dev Log  (${entries.length})',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                            ),
                          ),
                          const Spacer(),
                          GestureDetector(
                            onTap: _logger.clear,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              child: Text('CLEAR',
                                  style: TextStyle(
                                      color: Colors.orangeAccent,
                                      fontSize: 11,
                                      letterSpacing: 0.5)),
                            ),
                          ),
                          GestureDetector(
                            onTap: () => setState(() => _open = false),
                            child: const Padding(
                              padding: EdgeInsets.only(left: 4),
                              child: Icon(Icons.keyboard_arrow_down,
                                  color: Colors.white70, size: 24),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                        height: 1,
                        color: Colors.greenAccent.withOpacity(0.25)),

                    // ── Log entries ───────────────────────────────────────
                    Expanded(
                      child: entries.isEmpty
                          ? const Center(
                              child: Text('No logs yet',
                                  style: TextStyle(color: Colors.grey)))
                          : ListView.builder(
                              controller: _scroll,
                              padding: const EdgeInsets.symmetric(
                                  vertical: 4, horizontal: 6),
                              itemCount: entries.length,
                              itemBuilder: (context, i) {
                                final e = entries[i];
                                final t = e.time;
                                final ts =
                                    '${t.hour.toString().padLeft(2, '0')}:'
                                    '${t.minute.toString().padLeft(2, '0')}:'
                                    '${t.second.toString().padLeft(2, '0')}';
                                return Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 1),
                                  child: RichText(
                                    text: TextSpan(
                                      children: [
                                        TextSpan(
                                          text: '$ts ',
                                          style: const TextStyle(
                                            color: Color(0xFF777799),
                                            fontSize: 10,
                                            fontFamily: 'monospace',
                                          ),
                                        ),
                                        TextSpan(
                                          text: e.message,
                                          style: TextStyle(
                                            color: _colorFor(e.message),
                                            fontSize: 11,
                                            fontFamily: 'monospace',
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Bug FAB ─────────────────────────────────────────────────
            AnimatedPositioned(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOut,
              bottom: _open ? panelH + 8 : 88,
              right: 10,
              child: GestureDetector(
                onTap: () {
                  setState(() => _open = !_open);
                  if (_open) _scrollToBottom();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: _open
                        ? Colors.red.shade900
                        : Colors.black.withOpacity(0.78),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color:
                          _open ? Colors.redAccent : Colors.greenAccent,
                      width: 1.5,
                    ),
                  ),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Center(
                        child: Icon(
                          _open ? Icons.close : Icons.bug_report,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                      if (!_open && entries.isNotEmpty)
                        Positioned(
                          top: -3,
                          right: -3,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                            constraints: const BoxConstraints(
                                minWidth: 15, minHeight: 15),
                            child: Text(
                              entries.length > 99
                                  ? '99+'
                                  : '${entries.length}',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 8),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Colour-codes log lines by content.
  static Color _colorFor(String msg) {
    final lo = msg.toLowerCase();
    if (lo.contains('error') ||
        lo.contains('failed') ||
        lo.contains('exception') ||
        lo.contains('crash')) {
      return const Color(0xFFFF6B6B); // red
    }
    if (lo.contains('warn')) return const Color(0xFFFFD166); // amber
    if (msg.contains('[Threads]') ||
        msg.contains('[FB]') ||
        msg.contains('[IG]') ||
        msg.contains('[Login') ||
        msg.contains('[Download') ||
        msg.contains('[X]')) {
      return const Color(0xFF6BFF9E); // green — service logs
    }
    return Colors.white70;
  }
}
