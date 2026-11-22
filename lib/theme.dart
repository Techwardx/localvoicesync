import 'package:flutter/material.dart';

/// 宋代青碧 · 设计令牌（Design Tokens）
///
/// 整套界面按「素雅、留白、极细层级」来组织：
/// - 底色取月白（极淡冷白）与青白（近白的瓷色），不用纯白；
/// - 主色取天水碧一系的沉稳青碧，只用在真正需要强调的地方；
/// - 墨灰负责所有次要信息，缃色只做米粒大的状态点缀，绝不铺面；
/// - 信息层级靠字号、字重、行高与留白建立，少用阴影、描边与胶囊。
///
/// 颜色常量名保持向后兼容（记录页、待办页等仍引用 AppTheme.primary 等），
/// 新增的 [AppType] / [AppSpace] 是给新排版用的语义令牌。
class AppTheme {
  const AppTheme._();

  // ── 基底：月白 / 青白 ───────────────────────────────────────────
  /// 月白：页面底色，极淡的冷白，带一丝青意。
  static const Color background = Color(0xFFF5F7F5);

  /// 青白：瓷白卡片面，比底色略亮，接近白但不是纯白。
  static const Color surface = Color(0xFFFBFCFB);

  /// 比 surface 更沉一档的浅青，用于选中态底、引用块。
  static const Color surfaceSoft = Color(0xFFEFF4F1);

  // ── 文字：墨 / 墨灰 ─────────────────────────────────────────────
  /// 墨：正文与标题，非纯黑。
  static const Color ink = Color(0xFF222725);

  /// 墨灰：次要信息、说明文字。
  static const Color muted = Color(0xFF656C68);

  /// 淡墨灰：时间戳、ID 等最弱一级信息。
  static const Color faint = Color(0xFF959B97);

  /// 极细分割线，带青灰倾向。
  static const Color hairline = Color(0xFFE3E9E5);

  // ── 强调：天水碧 / 缃色 ─────────────────────────────────────────
  /// 天水碧（深）：主色，用于按钮、链接、选中文字，保证浅底上的对比。
  static const Color primary = Color(0xFF3E6F68);

  /// 天水碧（浅）：选中态底、柔和强调底。
  static const Color primarySoft = Color(0xFFDCEAE6);

  /// 天水碧（中）：比 primary 稍亮，用于图表、进度。
  static const Color primaryMid = Color(0xFF5E938B);

  /// 缃色：暖黄点缀，只用于米粒大的状态点，严禁大面积铺色。
  static const Color accent = Color(0xFFC08A44);

  /// 朱（沉）：错误、删除，压低饱和避免刺眼。
  static const Color danger = Color(0xFFA85049);

  // ── 连接状态灯 ─────────────────────────────────────────────────
  /// 已连接：青碧绿。
  static const Color online = Color(0xFF4C8579);

  /// 待处理 / 离线：缃色。
  static const Color pending = Color(0xFFC08A44);

  /// 未配置 / 连接中：淡墨灰。
  static const Color idleDot = Color(0xFFAFB6B1);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.light,
      surface: surface,
    ).copyWith(
      primary: primary,
      onPrimary: Colors.white,
      primaryContainer: primarySoft,
      onPrimaryContainer: const Color(0xFF1E4B45),
      secondary: muted,
      onSecondary: Colors.white,
      secondaryContainer: surfaceSoft,
      onSecondaryContainer: ink,
      tertiary: accent,
      onTertiary: Colors.white,
      error: danger,
      onError: Colors.white,
      surface: surface,
      onSurface: ink,
      surfaceContainerHighest: surfaceSoft,
      onSurfaceVariant: muted,
      outline: hairline,
      outlineVariant: const Color(0xFFEDF1EE),
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
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        foregroundColor: ink,
        titleTextStyle: const TextStyle(
          color: ink,
          fontSize: 19,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          height: 1.3,
        ),
        iconTheme: const IconThemeData(color: muted, size: 21),
      ),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpace.radiusCard),
          side: const BorderSide(color: hairline, width: 0.8),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: hairline,
        thickness: 0.8,
        space: 1,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surfaceSoft,
        side: BorderSide.none,
        labelStyle: const TextStyle(
          color: muted,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpace.radiusChip),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        hintStyle: const TextStyle(color: faint, fontSize: 14),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpace.radiusField),
          borderSide: const BorderSide(color: hairline, width: 0.8),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpace.radiusField),
          borderSide: const BorderSide(color: hairline, width: 0.8),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpace.radiusField),
          borderSide: const BorderSide(color: primary, width: 1.3),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpace.radiusField),
          ),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          side: const BorderSide(color: hairline, width: 0.8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpace.radiusField),
          ),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: muted),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: ink,
        contentTextStyle: const TextStyle(color: Color(0xFFF3F6F4), fontSize: 13),
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpace.radiusField),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpace.radiusCard),
        ),
        titleTextStyle: const TextStyle(
          color: ink,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: const TextStyle(
          color: muted,
          fontSize: 13.5,
          height: 1.6,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppSpace.radiusCard),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shadowColor: Colors.transparent,
        indicatorColor: primarySoft,
        height: 60,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith<IconThemeData>((states) {
          return IconThemeData(
            color: states.contains(WidgetState.selected) ? primary : faint,
            size: 21,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>((states) {
          return TextStyle(
            color: states.contains(WidgetState.selected) ? primary : muted,
            fontSize: 11,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
          );
        }),
      ),
    );
  }

  /// 统一的等宽小字，用于时间戳、ID 这类"机器味"信息。
  static const TextStyle mono = TextStyle(
    fontSize: 11,
    height: 1.45,
    color: faint,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );
}

/// 排版语义令牌。
///
/// 中文比西文更需要行高与字重来撑起层级——字号的差异反而要克制。
class AppType {
  const AppType._();

  /// 页面主标题（记录 / 搜索 / 设置）。
  static const TextStyle pageTitle = TextStyle(
    fontSize: 24,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    color: AppTheme.ink,
  );

  /// 卡片标题 / 记录标题。
  static const TextStyle title = TextStyle(
    fontSize: 15.5,
    height: 1.45,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    color: AppTheme.ink,
  );

  /// 正文。
  static const TextStyle body = TextStyle(
    fontSize: 14,
    height: 1.7,
    color: AppTheme.ink,
  );

  /// 摘要 / 次要正文。
  static const TextStyle secondary = TextStyle(
    fontSize: 13,
    height: 1.65,
    color: AppTheme.muted,
  );

  /// 分组小标题：靠字重与字距，不靠颜色块。
  static const TextStyle section = TextStyle(
    fontSize: 12,
    height: 1.4,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.6,
    color: AppTheme.muted,
  );

  /// 说明文字。
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    height: 1.55,
    color: AppTheme.muted,
  );

  /// 最弱一级信息。
  static const TextStyle footnote = TextStyle(
    fontSize: 11,
    height: 1.55,
    color: AppTheme.faint,
  );
}

/// 空间令牌（4pt 基准）。留白是这套视觉的主要手段，不是附属品。
class AppSpace {
  const AppSpace._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;

  /// 页面左右安全留白。
  static const double pageInset = 20;

  static const double radiusChip = 8;
  static const double radiusField = 12;
  static const double radiusCard = 16;
}
