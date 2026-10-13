/// 「游戏运行记录」内容拼装的测试（`lib/local/game_run_record.dart`）。
///
/// ## 为什么值得测
///
/// 这份记录是「小说改游戏」流水线 `game-qa` 那一环**唯一**的真机证据
/// （手机上不能自动截 WebView 的图，所以改由人玩过之后勾选）。
/// 它一旦拼错，模型会拿到一份**误导性的**验收结果 —— 比如把"没通过"写成"通过"、
/// 或者丢掉玩家写的备注（那正是最有价值的线索）。所以这里逐项钉住。
library;

import 'package:dsh_mobile/local/game_run_record.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final at = DateTime(2026, 10, 12, 16, 30);

  List<GameRunCheck> checks(List<bool> oks) => <GameRunCheck>[
        for (var i = 0; i < kGameRunQuestions.length; i += 1)
          GameRunCheck(question: kGameRunQuestions[i], ok: i < oks.length ? oks[i] : false),
      ];

  group('运行记录的内容', () {
    test('抬头：文件名 / 路径 / 时间 / 通过数都对', () {
      final md = buildRunRecordMarkdown(
        fileName: 'index.html',
        filePath: '/w/game/index.html',
        checks: checks(<bool>[true, true, false]),
        notes: '第三项卡住了',
        at: at,
      );
      expect(md, contains('# 游戏运行记录 · index.html'));
      expect(md, contains('`/w/game/index.html`'));
      expect(md, contains('2026-10-12 16:30'));
      expect(md, contains('**2 / 5**'), reason: '通过数要照实算（这里是 2/5）');
    });

    test('逐项结果：通过写"通过"，没通过要**显式标出来**（不能含糊）', () {
      final md = buildRunRecordMarkdown(
        fileName: 'g.html',
        filePath: '/w/g.html',
        checks: checks(<bool>[true, false, false, false, false]),
        notes: '',
        at: at,
      );
      expect(md, contains('| ${kGameRunQuestions[0]} | 通过 |'));
      for (var i = 1; i < kGameRunQuestions.length; i += 1) {
        expect(md, contains('| ${kGameRunQuestions[i]} | **没通过** |'),
            reason: '第 ${i + 1} 项没通过必须显式标注');
      }
    });

    test('玩家备注原样进（没有就写清楚，不留空）', () {
      final a = buildRunRecordMarkdown(
          fileName: 'g.html', filePath: '/w/g.html', checks: checks(<bool>[]), notes: '  点按没反应  ', at: at);
      expect(a, contains('点按没反应'));
      expect(a, isNot(contains('（没有写备注）')), reason: '有备注就不该出现占位');
      final b = buildRunRecordMarkdown(
          fileName: 'g.html', filePath: '/w/g.html', checks: checks(<bool>[]), notes: '   ', at: at);
      expect(b, contains('（没有写备注）'));
    });

    test('必须写明"这不是自动截图"，别让模型以为是截图证据', () {
      final md = buildRunRecordMarkdown(
          fileName: 'g.html', filePath: '/w/g.html', checks: checks(<bool>[]), notes: '', at: at);
      expect(md, contains('不是自动截图'));
      expect(md, contains('WebView'));
    });

    test('结尾要提醒模型：**别把这份记录当成"全部通过"**（零通过时尤其）', () {
      final md = buildRunRecordMarkdown(
          fileName: 'g.html', filePath: '/w/g.html', checks: checks(<bool>[]), notes: '', at: at);
      expect(md, contains('0 / 5'));
      expect(md, contains('game-qa'), reason: '要指向技能里的验收口径');
      expect(md, contains('已知限制'), reason: '要提醒把未覆盖项与已知限制写清');
      expect(md, contains('不要'), reason: '要明确说"别当成全部通过"');
    });

    test('五项问题就是 game-qa 那几条（改动会牵到技能，所以钉住条数）', () {
      expect(kGameRunQuestions.length, 5);
      for (final q in kGameRunQuestions) {
        expect(q.trim(), isNotEmpty);
      }
      expect(kGameRunQuestions.join(), contains('画面'));
      expect(kGameRunQuestions.join(), contains('核心循环'));
      expect(kGameRunQuestions.join(), contains('结局'));
      expect(kGameRunQuestions.join(), contains('重新开始'));
    });
  });

  group('文件名', () {
    test('带时间戳 + 原文件名，方便按时间排', () {
      final n = runRecordFileName('game.html', at);
      expect(n, '游戏运行记录-game.html-2026-10-12 16:30.md');
    });

    test('文件名里的非法字符会被替换（否则在 Android 上写不出去）', () {
      final n = runRecordFileName('a/b:c*d?.html', at);
      for (final bad in <String>['/', ':', '*', '?']) {
        expect(n.split('-2026')[0].contains(bad), isFalse, reason: '还留着 $bad');
      }
      expect(n, endsWith('.md'));
    });
  });
}
