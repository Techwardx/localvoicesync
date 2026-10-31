import 'app_config.dart';

/// 家庭成员（作者）定义。
///
/// 三件事必须同时成立，否则多设备共享会互相踩踏：
/// 1. [author]  —— 写进 JSON 契约的 `author` 字段（ASCII，跨平台安全）；
/// 2. [dirName] —— 同步目录名，Mac 端与 Syncthing 靠它做多域隔离；
/// 3. [label]   —— 界面展示用的中文名。
class FamilyMember {
  const FamilyMember({
    required this.id,
    required this.author,
    required this.label,
    required this.dirName,
  });

  final String id;
  final String author;
  final String label;
  final String dirName;

  static const FamilyMember me = FamilyMember(
    id: 'me',
    author: 'Me',
    label: '我',
    dirName: 'Me_Notes',
  );

  static const FamilyMember dad = FamilyMember(
    id: 'dad',
    author: 'Dad',
    label: '爸爸',
    dirName: 'Dad_Notes',
  );

  static const FamilyMember mom = FamilyMember(
    id: 'mom',
    author: 'Mom',
    label: '妈妈',
    dirName: 'Mom_Notes',
  );

  /// 内置成员。自定义成员不在这个列表里，由 [resolve] 动态生成。
  static const List<FamilyMember> builtIns = <FamilyMember>[me, dad, mom];

  static const String customId = 'custom';

  /// 把任意用户输入压成安全的目录名 / 作者名。
  static String slugify(String raw) {
    final buffer = StringBuffer();
    for (final rune in raw.trim().runes) {
      final ch = String.fromCharCode(rune);
      final isAsciiLetter = RegExp(r'[A-Za-z0-9_-]').hasMatch(ch);
      if (isAsciiLetter) {
        buffer.write(ch);
      } else if (RegExp(r'[\u4e00-\u9fff]').hasMatch(ch)) {
        // 中文无法直接做目录名时的稳定映射：用码点十六进制，保证同一名字永远同目录。
        buffer.write('u${rune.toRadixString(16)}');
      } else if (ch == ' ') {
        buffer.write('_');
      }
    }
    final slug = buffer.toString();
    return slug.isEmpty ? 'Member' : slug;
  }

  /// 根据持久化的配置解析出成员对象。
  static FamilyMember resolve({required String authorId, String? customName}) {
    for (final member in builtIns) {
      if (member.id == authorId) return member;
    }
    final name = (customName == null || customName.trim().isEmpty)
        ? 'Member'
        : customName.trim();
    final slug = slugify(name);
    return FamilyMember(
      id: customId,
      author: slug,
      label: name,
      dirName: '${slug}_Notes',
    );
  }

  Map<String, String> toPrefs() => <String, String>{
    'author_id': id,
    'author_label': label,
    'author_dir': dirName,
  };

  @override
  String toString() => '$label($author → $dirName)';
}

/// 本机设备标识：用于区分"同一作者在不同设备上"的记录来源。
class DeviceIdentity {
  const DeviceIdentity({required this.deviceId, required this.deviceLabel});

  final String deviceId;
  final String deviceLabel;

  /// 首次启动时生成一次，之后永久持久化，保证 id 稳定。
  static String generate() {
    final now = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    return '${AppConfig.deviceIdPrefix}$now';
  }
}
