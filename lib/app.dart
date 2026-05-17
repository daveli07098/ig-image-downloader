import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'widgets/dev_log_overlay.dart';

class IgDownloaderApp extends StatelessWidget {
  const IgDownloaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IG Downloader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE1306C), // Instagram pink
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        fontFamily: 'sans-serif',
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE1306C),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      // DevLogOverlay is a no-op in release builds (kDebugMode guard inside).
      // In debug builds it shows a slide-up log panel via the bug-icon FAB.
      builder: (context, child) =>
          DevLogOverlay(child: child ?? const SizedBox()),
      home: const HomeScreen(),
    );
  }
}
