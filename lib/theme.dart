import 'package:flutter/material.dart';

/// 配色：暖白纸感 + 深墨绿主色。
///
/// 语音备忘是个"高频、短时、随手"的场景，界面要安静，
/// 所以主色饱和度压低，靠圆点和留白引导注意力，而不是靠大色块。
class AppTheme {
  const AppTheme._();

  static const Color background = Color(0xFFF6F5F1);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color ink = Color(0xFF1C1B19);
  static const Color muted = Color(0xFF6E6A63);
  static const Color hairline = Color(0xFFE5E2DA);
  static const Color primary = Color(0xFF1F6F5C);
  static const Color primarySoft = Color(0xFFE3EFEA);
  static const Color accent = Color(0xFFC2762F);
  static const Color danger = Color(0xFFB3453A);

  /// 连接指示灯的颜色（绿 / 黄 / 灰）。
  static const Color online = Color(0xFF2E9E6B);
  static const Color pending = Color(0xFFD8A22A);
  static const Color idleDot = Color(0xFFB8B3A8);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.light,
      surface: surface,
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      fontFamilyFallback: const <String>[
        'PingFang SC',
        'Noto Sans CJK SC',
        'Source Han Sans SC',
        'Microsoft YaHei',
      ],
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: ink,
        displayColor: ink,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        foregroundColor: ink,
        titleTextStyle: TextStyle(
          color: ink,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: hairline),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: hairline,
        thickness: 1,
        space: 1,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: primarySoft,
        side: BorderSide.none,
        labelStyle: const TextStyle(
          color: primary,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        hintStyle: const TextStyle(color: muted, fontSize: 14),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primary, width: 1.4),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: ink,
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }

  /// 统一的等宽小字，用于时间戳、ID 这类"机器味"信息。
  static const TextStyle mono = TextStyle(
    fontSize: 11,
    height: 1.4,
    color: muted,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );
}
