import 'package:flutter_test/flutter_test.dart';
import 'package:local_voice_sync/core/app_config.dart';
import 'package:local_voice_sync/services/memo_edit_service.dart';

/// 编辑页标签清洗的回归测试。
///
/// 这些规则看起来琐碎，但每一条都对应一次真实的翻车：
/// 空标签会让 Mac 端 `resolve_user` 输出一个空字符串；大小写重复会让
/// 标签云里出现「QCY」和「qcy」两个；超长标签会被 Mac 静默丢弃，用户
/// 却以为保存成功了。
void main() {
  group('编辑标签清洗', () {
    test('去掉首尾空白，空值不占位', () {
      expect(
        MemoEditService.cleanTags(['  手语 ', '', '   ', '无障碍']),
        ['手语', '无障碍'],
      );
    });

    test('大小写重复只留第一次出现的写法', () {
      // 品牌名保留用户原本的大小写，但不会重复出现两个。
      expect(MemoEditService.cleanTags(['QCY', 'qcy', 'Qcy']), ['QCY']);
    });

    test('保留用户写的顺序', () {
      expect(
        MemoEditService.cleanTags(['无障碍', '手语', 'QCY T20']),
        ['无障碍', '手语', 'QCY T20'],
      );
    });

    test('超过上限的部分被截断', () {
      final raw = List<String>.generate(20, (i) => '标签$i');
      final cleaned = MemoEditService.cleanTags(raw);
      expect(cleaned.length, AppConfig.maxUserTags);
      expect(cleaned.first, '标签0');
    });

    test('超长标签直接丢弃（Mac 端也会丢）', () {
      final long = 'x' * (AppConfig.maxTagLength + 1);
      expect(MemoEditService.cleanTags([long, '手语']), ['手语']);
    });

    test('刚好到长度上限的标签保留', () {
      final exact = 'x' * AppConfig.maxTagLength;
      expect(MemoEditService.cleanTags([exact]), [exact]);
    });

    test('空输入返回空列表', () {
      expect(MemoEditService.cleanTags(const []), isEmpty);
    });
  });
}
