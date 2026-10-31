import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_log.dart';
import '../core/family_member.dart';
import 'syncthing_service.dart';

/// 用户配置。全部落在 SharedPreferences（系统级持久化，卸载才丢）。
class AppSettings {
  const AppSettings({
    required this.authorId,
    required this.customAuthorName,
    required this.deviceId,
    required this.syncthing,
    required this.onboardingDone,
  });

  final String authorId;
  final String customAuthorName;
  final String deviceId;
  final SyncthingConfig syncthing;
  final bool onboardingDone;

  FamilyMember get member => FamilyMember.resolve(
    authorId: authorId,
    customName: customAuthorName,
  );

  static AppSettings initial() => AppSettings(
    authorId: FamilyMember.me.id,
    customAuthorName: '',
    deviceId: DeviceIdentity.generate(),
    syncthing: const SyncthingConfig(),
    onboardingDone: false,
  );

  AppSettings copyWith({
    String? authorId,
    String? customAuthorName,
    String? deviceId,
    SyncthingConfig? syncthing,
    bool? onboardingDone,
  }) => AppSettings(
    authorId: authorId ?? this.authorId,
    customAuthorName: customAuthorName ?? this.customAuthorName,
    deviceId: deviceId ?? this.deviceId,
    syncthing: syncthing ?? this.syncthing,
    onboardingDone: onboardingDone ?? this.onboardingDone,
  );
}

/// 配置读写。刻意保持"读失败就用默认值"的宽容策略——
/// 一个配置项损坏绝不该让用户打不开 App。
class SettingsStore {
  static const String _kAuthorId = 'settings.author_id';
  static const String _kCustomName = 'settings.custom_author_name';
  static const String _kDeviceId = 'settings.device_id';
  static const String _kSyncthing = 'settings.syncthing';
  static const String _kOnboarding = 'settings.onboarding_done';

  Future<AppSettings> load() async {
    final fallback = AppSettings.initial();
    try {
      final prefs = await SharedPreferences.getInstance();
      final deviceId = prefs.getString(_kDeviceId);
      if (deviceId == null || deviceId.isEmpty) {
        await prefs.setString(_kDeviceId, fallback.deviceId);
      }
      SyncthingConfig syncthing = const SyncthingConfig();
      final rawSyncthing = prefs.getString(_kSyncthing);
      if (rawSyncthing != null && rawSyncthing.isNotEmpty) {
        try {
          final decoded = jsonDecode(rawSyncthing);
          if (decoded is Map) {
            syncthing = SyncthingConfig.fromJson(
              decoded.map((key, value) => MapEntry(key.toString(), value)),
            );
          }
        } on FormatException {
          AppLog.w('settings', 'Syncthing 配置损坏，回退默认值');
        }
      }
      return AppSettings(
        authorId: prefs.getString(_kAuthorId) ?? fallback.authorId,
        customAuthorName: prefs.getString(_kCustomName) ?? '',
        deviceId: (deviceId == null || deviceId.isEmpty)
            ? fallback.deviceId
            : deviceId,
        syncthing: syncthing,
        onboardingDone: prefs.getBool(_kOnboarding) ?? false,
      );
    } on Object catch (error) {
      AppLog.w('settings', '读取配置失败，使用默认值：$error');
      return fallback;
    }
  }

  Future<void> save(AppSettings settings) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAuthorId, settings.authorId);
      await prefs.setString(_kCustomName, settings.customAuthorName);
      await prefs.setString(_kDeviceId, settings.deviceId);
      await prefs.setString(_kSyncthing, jsonEncode(settings.syncthing.toJson()));
      await prefs.setBool(_kOnboarding, settings.onboardingDone);
    } on Object catch (error) {
      AppLog.w('settings', '保存配置失败：$error');
    }
  }
}
