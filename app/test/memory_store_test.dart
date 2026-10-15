/// 「用户记忆」的测试。
///
/// ## 这一组为什么必须存在
///
/// 记忆这条链路的失效方式**全是静默的**：写错了不会崩、界面照常显示，
/// 但模型看不到（或看到**已经删掉的内容**）。而且它和「专家」开关**共用同一个文件**
/// `$DSH_HOME/AGENTS.md` —— 两个写者互相覆盖是最可能的事故，必须钉住。
///
/// 覆盖：块读写 / 与专家块共存（双向）/ 块**前置**（截断先砍尾部）/ 标记注入 /
/// 预算回滚（不留半份）/ 删除同步 / 幂等 / 原子写不留 .part / 坏 JSON 不覆盖磁盘
/// —— 以上是 v1 时代就有的。
///
/// v2 追加（本轮）：**v1 → v2 无损读**（对象形态与裸数组形态）/ v2 往返保真 /
/// 总开关（关掉 = 整块移除、重开写回、关着也不越权写入）/ workspace 范围的路径声明 /
/// 分类分组与组内重要度排序 / 搜索 / moveToTop / 导入去重与坏 JSON / 导出往返 /
/// 导入超预算如实报数 / i18n 锚点与枚举文案同步。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/data/expert_store.dart';
import 'package:dsh_mobile/data/memory_store.dart';

void main() {
  late Directory dir;
  late MemoryStore store;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('dsh-memory-test');
    store = MemoryStore(dshHome: dir.path);
    await store.load();
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File agentsMd() => File('${dir.path}/AGENTS.md');
  File stateJson() => File('${dir.path}/memory.json');
  String readAgents() =>
      agentsMd().existsSync() ? agentsMd().readAsStringSync() : '';
  Map<String, dynamic> readState() =>
      jsonDecode(stateJson().readAsStringSync()) as Map<String, dynamic>;

  group('基本读写', () {
    test('没有文件时 load 不报错、是空记忆，且不去创建 AGENTS.md', () async {
      expect(store.count, 0);
      expect(store.loaded, isTrue);
      expect(agentsMd().existsSync(), isFalse,
          reason: '空记忆不该凭空造一个 AGENTS.md 出来');
    });

    test('add 之后：memory.json 落盘 + AGENTS.md 出现受管区块', () async {
      final err = await store.add('回答用中文，先给结论。');
      expect(err, isNull);
      expect(store.count, 1);
      expect(stateJson().existsSync(), isTrue);

      final text = readAgents();
      expect(text, contains(MemoryStore.blockBegin));
      expect(text, contains(MemoryStore.blockEnd));
      expect(text, contains('回答用中文，先给结论。'));
    });

    test('重开（新实例 load）能读回来 —— 这就是"跨重启记住"', () async {
      await store.add('我是中文用户');
      final again = MemoryStore(dshHome: dir.path);
      await again.load();
      expect(again.count, 1);
      expect(again.entries.first.text, '我是中文用户');
    });

    test('remove 会同步把内容从 AGENTS.md 里去掉（否则模型还看得到）', () async {
      await store.add('这条要被删掉');
      expect(readAgents(), contains('这条要被删掉'));

      await store.remove(store.entries.first.id);
      expect(store.count, 0);
      expect(readAgents(), isNot(contains('这条要被删掉')));
      expect(readAgents(), isNot(contains(MemoryStore.blockBegin)));
    });

    test('clearAll 清空后如果文件里没有别的内容，就把 AGENTS.md 删掉', () async {
      await store.add('一条');
      expect(agentsMd().existsSync(), isTrue);
      await store.clearAll();
      expect(agentsMd().existsSync(), isFalse,
          reason: '没有任何内容时不该留一个空文件');
    });

    test('move 改注入顺序（靠前的更"重要"，被截断时也活得更久）', () async {
      await store.add('第一条');
      await store.add('第二条');
      await store.move(store.entries.last.id, -1);
      expect(store.entries.map((e) => e.text).toList(), <String>['第二条', '第一条']);
      // 渲染顺序也要跟着变
      final text = readAgents();
      expect(text.indexOf('第二条'), lessThan(text.indexOf('第一条')));
    });

    test('moveToTop 把一条直接挪到最前', () async {
      await store.add('A');
      await store.add('B');
      await store.add('C');
      final err = await store.moveToTop(store.entries.last.id);
      expect(err, isNull);
      expect(store.entries.map((e) => e.text).toList(), <String>['C', 'A', 'B']);
      // 已经是最前的那条再置顶 = 什么都不做（不报错、不重排）
      expect(await store.moveToTop(store.entries.first.id), isNull);
      expect(store.entries.map((e) => e.text).toList(), <String>['C', 'A', 'B']);
    });
  });

  group('v2 数据模型（含 v1 无损兼容）', () {
    test('v1 对象形态无损读：文本/时间原样，缺的字段取默认值', () async {
      stateJson().writeAsStringSync(jsonEncode(<String, dynamic>{
        'entries': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'm1',
            'text': '我是中文用户',
            'createdAt': '2026-01-02T03:04:05.000',
          },
        ],
      }));
      final s = MemoryStore(dshHome: dir.path);
      await s.load();
      expect(s.count, 1);
      final e = s.entries.first;
      expect(e.text, '我是中文用户');
      expect(e.id, 'm1');
      expect(e.createdAt.toIso8601String(), '2026-01-02T03:04:05.000');
      expect(e.kind, MemoryKind.other, reason: 'v1 没有 kind → other');
      expect(e.importance, 2, reason: 'v1 没有 importance → 2');
      expect(e.scope, MemoryScope.global);
      expect(e.workspace, isNull);
      expect(e.source, MemorySource.manual);
      expect(s.enabled, isTrue, reason: 'v1 没有 settings → 默认打开注入');
      expect(s.autoSuggest, isFalse);
    });

    test('v1 裸数组形态也能读（老版本真的有这种写法）', () async {
      stateJson().writeAsStringSync(jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{'id': 'm9', 'text': '裸数组里的'},
      ]));
      final s = MemoryStore(dshHome: dir.path);
      await s.load();
      expect(s.count, 1);
      expect(s.entries.first.text, '裸数组里的');
      expect(s.entries.first.kind, MemoryKind.other);
    });

    test('落盘一定是 v2：version / settings / entries / updatedAt 都在', () async {
      await store.add('一条');
      final m = readState();
      expect(m['version'], 2);
      expect((m['settings'] as Map)['enabled'], isTrue);
      expect((m['settings'] as Map)['autoSuggest'], isFalse);
      expect(m['entries'], isA<List<dynamic>>());
      expect(DateTime.tryParse(m['updatedAt'] as String), isNotNull);
    });

    test('v2 往返保真：分类/重要度/范围/来源/工作目录路径全在', () async {
      await store.add(
        '这个项目用 Flutter',
        kind: MemoryKind.project,
        importance: 1,
        scope: MemoryScope.workspace,
        workspace: '/root/办公/dsh-mobile',
      );
      await store.addFromCandidate(
        text: '模型提炼出来的',
        kind: MemoryKind.preference,
        importance: 3,
      );
      final again = MemoryStore(dshHome: dir.path);
      await again.load();
      final a = again.entries[0];
      expect(a.kind, MemoryKind.project);
      expect(a.importance, 1);
      expect(a.scope, MemoryScope.workspace);
      expect(a.workspace, '/root/办公/dsh-mobile');
      expect(a.source, MemorySource.manual);
      final b = again.entries[1];
      expect(b.kind, MemoryKind.preference);
      expect(b.importance, 3);
      expect(b.source, MemorySource.extracted,
          reason: 'addFromCandidate 的来源必须是 extracted（界面要标出来）');
    });

    test('重要度越界被夹到 1..3（脏数据不丢、也不越界）', () async {
      await store.add('太大', importance: 9);
      await store.add('太小', importance: 0);
      expect(store.entries[0].importance, 3);
      expect(store.entries[1].importance, 1);
    });

    test('认不出来的 kind 落成 other（不丢这条记忆）', () async {
      stateJson().writeAsStringSync(jsonEncode(<String, dynamic>{
        'version': 2,
        'entries': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'm1', 'text': '一条', 'kind': 'unknown-kind'},
        ],
      }));
      final s = MemoryStore(dshHome: dir.path);
      await s.load();
      expect(s.entries.first.kind, MemoryKind.other);
    });

    test('update 能改文本/分类/重要度/范围，并立刻重写注入块', () async {
      await store.add('原来');
      final id = store.entries.first.id;
      final err = await store.update(
        id,
        text: '改过',
        kind: MemoryKind.avoid,
        importance: 1,
        scope: MemoryScope.workspace,
        workspace: '/tmp/ws',
      );
      expect(err, isNull);
      final e = store.entries.first;
      expect(e.text, '改过');
      expect(e.kind, MemoryKind.avoid);
      expect(e.importance, 1);
      expect(e.isWorkspaceScoped, isTrue);
      expect(readAgents(), contains('仅当工作目录是 /tmp/ws 时适用'));
    });

    test('update 想改成 workspace 却拿不到路径 → 拒绝并保持原样', () async {
      await store.add('一条');
      final id = store.entries.first.id;
      final err = await store.update(id, scope: MemoryScope.workspace);
      expect(err, isNotNull);
      final e = store.entries.first;
      expect(e.scope, MemoryScope.global);
      expect(e.workspace, isNull);
    });

    test('search 是纯本地过滤：按内容、分类名、范围名', () async {
      await store.add('我是中文用户', kind: MemoryKind.identity);
      await store.add('不要动生产库', kind: MemoryKind.avoid);
      expect(store.search('中文').length, 1);
      expect(store.search('中文').first.text, '我是中文用户');
      expect(store.search('不要做的事').length, 1, reason: '分类名也要能搜到');
      expect(store.search('全局').length, 2, reason: '范围名也要能搜到');
      expect(store.search('').length, 2, reason: '空查询 = 全部');
      expect(store.search('根本没有的东西'), isEmpty);
    });
  });

  group('总开关（enabled）', () {
    test('关掉：AGENTS.md 里的**整块**移除，但条目留在 memory.json 里', () async {
      await store.add('一条');
      expect(readAgents(), contains('一条'));

      final err = await store.setEnabled(false);
      expect(err, isNull);
      expect(store.enabled, isFalse);
      expect(readAgents(), isNot(contains(MemoryStore.blockBegin)));
      expect(readAgents(), isNot(contains('一条')),
          reason: '关掉总开关后模型不该再看到这条');
      expect(store.count, 1, reason: '关掉注入 ≠ 删除条目，页面还要能管理它');
      final m = readState();
      expect((m['entries'] as List).length, 1);
      expect((m['settings'] as Map)['enabled'], isFalse, reason: '开关要落盘');
    });

    test('重新打开：同一批条目原样写回 AGENTS.md', () async {
      await store.add('一条');
      await store.setEnabled(false);
      expect(readAgents(), isNot(contains('一条')));

      final err = await store.setEnabled(true);
      expect(err, isNull);
      expect(readAgents(), contains('一条'));
      expect(readAgents(), contains(MemoryStore.blockBegin));
    });

    test('关着的时候新加的条目**不许**偷偷写进 AGENTS.md', () async {
      await store.setEnabled(false);
      await store.add('关着加的');
      expect(store.count, 1);
      expect(readAgents(), isNot(contains('关着加的')));
      // 打开后它才出现
      await store.setEnabled(true);
      expect(readAgents(), contains('关着加的'));
    });

    test('关着时 ensureAgentsMd 会把残留的旧块清掉（幂等）', () async {
      await store.add('一条');
      await store.setEnabled(false);
      // 手工把块塞回去，模拟"界面说关了、文件里还留着"
      agentsMd().writeAsStringSync(
          '${MemoryStore.blockBegin}\n> 一条\n${MemoryStore.blockEnd}\n');
      await store.ensureAgentsMd();
      expect(readAgents(), isNot(contains(MemoryStore.blockBegin)));
    });

    test('setEnabled 幂等：状态没变就不写盘、不报错', () async {
      await store.add('一条');
      final before = readState()['updatedAt'];
      expect(await store.setEnabled(true), isNull);
      expect(readState()['updatedAt'], before, reason: '没变化不该产生一次写盘');
    });

    test('setAutoSuggest 只改配置，不重写注入块', () async {
      await store.add('一条');
      final before = readAgents();
      expect(await store.setAutoSuggest(true), isNull);
      expect(store.autoSuggest, isTrue);
      expect(readAgents(), before, reason: '这个开关不影响注入内容，别白写一遍文件');
      expect((readState()['settings'] as Map)['autoSuggest'], isTrue);
    });
  });

  group('注入渲染：分组 / 排序 / 范围声明', () {
    test('按分类分组，组内按重要度升序（1 在前），同级保持用户顺序', () async {
      await store.add('身份-低', kind: MemoryKind.identity, importance: 3);
      await store.add('身份-高', kind: MemoryKind.identity, importance: 1);
      await store.add('身份-中', kind: MemoryKind.identity, importance: 2);
      await store.add('禁忌-高', kind: MemoryKind.avoid, importance: 1);

      final t = readAgents();
      // 分组小标题：枚举顺序（身份 在 不要做的事 之前）
      expect(t.indexOf('### 身份'), greaterThan(0));
      expect(t.indexOf('### 身份'), lessThan(t.indexOf('### 不要做的事')));
      // 组内按重要度升序
      expect(t.indexOf('身份-高'), lessThan(t.indexOf('身份-中')));
      expect(t.indexOf('身份-中'), lessThan(t.indexOf('身份-低')));
      // 没有内容的分类不出现小标题
      expect(t, isNot(contains('### 偏好')));
      // 原有的安全说明不能被删掉
      expect(t, contains('与本次任务的临时要求冲突时以本次要求为准'));
    });

    test('workspace 范围：注入块里明确写出「仅当工作目录是 … 时适用」', () async {
      await store.add(
        '这个项目用 Flutter',
        kind: MemoryKind.project,
        scope: MemoryScope.workspace,
        workspace: '/root/办公/dsh-mobile',
      );
      final t = readAgents();
      expect(t, contains('仅当工作目录是 /root/办公/dsh-mobile 时适用'),
          reason: 'AGENTS.md 是全局文件，无法按会话切换 —— 只能如实标注，不能装作只在那个目录生效');
      expect(t, contains('这个项目用 Flutter'));
    });

    test('scope=workspace 但没有路径 → 拒绝，不写盘、不残留半条', () async {
      final err = await store.add('没有路径的记忆', scope: MemoryScope.workspace);
      expect(err, isNotNull);
      expect(store.count, 0);
      expect(stateJson().existsSync(), isFalse);
      expect(agentsMd().existsSync(), isFalse);
    });

    test('分类名与重要度档位都有中文名（界面直接用）', () {
      expect(MemoryKind.identity.label, '身份');
      expect(MemoryKind.preference.label, '偏好');
      expect(MemoryKind.project.label, '项目与事实');
      expect(MemoryKind.avoid.label, '不要做的事');
      expect(MemoryKind.other.label, '其它');
      expect(MemoryScope.global.label, '全局');
      expect(MemoryScope.workspace.label, '仅当前工作区');
      expect(MemorySource.manual.label, '手动添加');
      expect(MemorySource.extracted.label, '从会话提炼');
      expect(importanceLabel(1), '高');
      expect(importanceLabel(2), '中');
      expect(importanceLabel(3), '低');
    });

    test('lastPathSegment 取路径末段（列表里显示短名）', () {
      expect(lastPathSegment('/root/办公/dsh-mobile'), 'dsh-mobile');
      expect(lastPathSegment('/root/办公/dsh-mobile/'), 'dsh-mobile');
      expect(lastPathSegment('单段'), '单段');
      expect(lastPathSegment(''), '');
    });
  });

  group('导入 / 导出', () {
    test('导出 → 再导入：按 text 去重，新增 0 条', () async {
      await store.add('一条', kind: MemoryKind.avoid, importance: 1);
      final exported = store.exportJson();
      expect(exported, contains('"version": 2'));

      final r = await store.importJson(exported);
      expect(r.ok, isTrue);
      expect(r.added, 0);
      expect(r.skipped, 1);
      expect(store.count, 1);
    });

    test('导入：重复的跳过、新条目收下并保真，非法条目如实计入跳过', () async {
      await store.add('已有的一条');
      final r = await store.importJson(jsonEncode(<String, dynamic>{
        'version': 2,
        'entries': <Object?>[
          <String, dynamic>{'id': 'x1', 'text': '已有的一条'},
          <String, dynamic>{
            'id': 'x2',
            'text': '新来的一条',
            'kind': 'avoid',
            'importance': 1,
          },
          <String, dynamic>{'id': 'x3', 'text': '   '},
          '不是对象',
        ],
      }));
      expect(r.ok, isTrue);
      expect(r.added, 1);
      expect(r.skipped, 3);
      expect(store.count, 2);

      final imported = store.entries.firstWhere((e) => e.text == '新来的一条');
      expect(imported.kind, MemoryKind.avoid);
      expect(imported.importance, 1);
      expect(imported.source, MemorySource.manual);
      expect(imported.id, isNot('x2'),
          reason: 'id 必须重新生成：两台设备的 id 撞车会让"删一条"删掉两条');
      // 导出成 JSON 之后也要能读回来
      expect(readAgents(), contains('新来的一条'));
    });

    test('导入坏 JSON → 中文错误，且**不动**现有条目', () async {
      await store.add('已有的一条');
      final before = readAgents();
      final r = await store.importJson('{ 这不是 JSON');
      expect(r.ok, isFalse);
      expect(r.error, contains('导入失败'));
      expect(r.added, 0);
      expect(store.count, 1);
      expect(readAgents(), before);
    });

    test('导入：顶层既不是对象也不是数组 → 中文错误', () async {
      final r = await store.importJson('"就是一个字符串"');
      expect(r.ok, isFalse);
      expect(r.error, contains('导入失败'));
    });

    test('导入：对象里没有 entries 数组 → 中文错误', () async {
      final r = await store.importJson('{"version":2}');
      expect(r.ok, isFalse);
      expect(r.error, contains('entries'));
    });

    test('导入超预算：如实报条数，且磁盘与内存一致（不留半份）', () async {
      final items = <Map<String, dynamic>>[
        for (var i = 0; i < 12; i++)
          <String, dynamic>{
            'id': 'i$i',
            'text': '第$i条${'字' * 500}',
            'kind': 'other',
            'importance': 2,
          },
      ];
      final r = await store.importJson(
          jsonEncode(<String, dynamic>{'version': 2, 'entries': items}));
      expect(r.ok, isTrue);
      expect(r.overBudget, greaterThan(0), reason: '12 条 × 1.5KB 一定超 8KB');
      expect(store.usedBytes, lessThanOrEqualTo(MemoryStore.byteBudget));
      final m = readState();
      expect((m['entries'] as List).length, store.count,
          reason: '磁盘条目数与内存不一致 = 写进去了半份');
      expect(r.added + r.skipped + r.overBudget, 12);
    });

    test('导入一条都不新增时不写盘（updatedAt 不变）', () async {
      await store.add('一条');
      final before = readState()['updatedAt'];
      final r = await store.importJson(jsonEncode(<String, dynamic>{
        'entries': <Map<String, dynamic>>[
          <String, dynamic>{'text': '一条'},
        ],
      }));
      expect(r.added, 0);
      expect(readState()['updatedAt'], before);
    });
  });

  group('与专家块共存（同一个 AGENTS.md，两个写者）', () {
    test('记忆写入不会吃掉专家块，且记忆块在**前面**', () async {
      // 先让专家 store 真写一遍（没有目录 → 只写"本机执行环境"那段）
      final exp = ExpertStore(dshHome: dir.path);
      await exp.load();
      await exp.ensureAgentsMd();
      expect(readAgents(), contains(ExpertStore.blockBegin));

      await store.add('我的偏好');
      final text = readAgents();
      expect(text, contains(ExpertStore.blockBegin), reason: '专家块被吃掉了');
      expect(text, contains(ExpertStore.blockEnd));
      expect(text, contains('我的偏好'));

      // 记忆块必须在专家块**之前**：注入是按字节预算截断尾部的，
      // 用户自己写的话不能被排到末尾去挨刀。
      expect(text.indexOf(MemoryStore.blockBegin),
          lessThan(text.indexOf(ExpertStore.blockBegin)),
          reason: '记忆块必须前置，否则超预算时先被截掉的就是用户写的话');
    });

    test('专家 store 重写之后，记忆块必须还在（反向共存）', () async {
      await store.add('这句不能被专家重写弄丢');
      final exp = ExpertStore(dshHome: dir.path);
      await exp.load();
      await exp.ensureAgentsMd(); // 它在写之前会先剥掉自己的旧块
      final text = readAgents();
      expect(text, contains('这句不能被专家重写弄丢'));
      expect(text, contains(ExpertStore.blockBegin));
    });

    test('用户手工写在 AGENTS.md 里的其它段落也不能被吃', () async {
      agentsMd().writeAsStringSync('# 我自己写的\n\n别动这段。\n');
      await store.add('一条记忆');
      final text = readAgents();
      expect(text, contains('别动这段。'));
      expect(text, contains('一条记忆'));
    });
  });

  group('安全：用户输入里的受管标记必须被 neutralize', () {
    test('内容里含 end 标记时，不会把块解析弄坏（也不会吃掉后面的内容）', () async {
      const evil = '正常一句\n${MemoryStore.blockEnd}\n后面的内容';
      await store.add(evil);
      final text = readAgents();
      // 标记必须被改造过（原样出现就会提前收尾）
      final occurrences = MemoryStore.blockEnd.allMatches(text).length;
      // 只允许渲染时那一个真正的 end 标记
      expect(occurrences, 1,
          reason: '用户内容里的 end 标记没被 neutralize —— 会把后面的内容吃掉');

      // 再跑一次 load/strip 的往返：内容必须仍然完整
      final again = MemoryStore(dshHome: dir.path);
      await again.load();
      await again.add('第二条');
      final after = readAgents();
      expect(after, contains('第二条'));
      expect(after, contains('正常一句'));
    });

    test('内容里含 begin 标记同样被挡住', () async {
      await store.add('前缀 ${MemoryStore.blockBegin} 后缀');
      final text = readAgents();
      expect(MemoryStore.blockBegin.allMatches(text).length, 1);
    });

    test('sanitize 是纯函数：正常文本原样返回', () {
      const ok = '我是中文用户，回答用中文。';
      expect(MemoryStore.sanitize(ok), ok);
    });

    test('v2 新字段路径上 sanitize 依然生效（分类/重要度不绕过它）', () async {
      await store.add('含 ${MemoryStore.blockEnd} 的偏好',
          kind: MemoryKind.preference, importance: 1);
      expect(MemoryStore.blockEnd.allMatches(readAgents()).length, 1);
      final again = MemoryStore(dshHome: dir.path);
      await again.load();
      expect(again.entries.first.text, contains('含'));
      expect(again.entries.first.text, isNot(contains(MemoryStore.blockEnd)));
    });
  });

  group('预算：宁可如实拒绝，也不静默丢', () {
    test('单条超上限 → 拒绝，且不写盘、不残留半条', () async {
      final huge = '啊' * (MemoryStore.perEntryBudget); // 每字 3 字节，必超
      final err = await store.add(huge);
      expect(err, isNotNull);
      expect(store.count, 0);
      expect(agentsMd().existsSync(), isFalse, reason: '被拒绝的条目不该留下文件');
      expect(stateJson().existsSync(), isFalse);
    });

    test('总量超上限 → 拒绝并**回滚**（不能只写进去一半）', () async {
      // 每条约 1.5 KB（500 个汉字 × 3 字节），堆到超过 8 KB
      var rejected = false;
      for (var i = 0; i < 12; i++) {
        final err = await store.add('第$i条${'字' * 500}');
        if (err != null) {
          rejected = true;
          break;
        }
      }
      expect(rejected, isTrue, reason: '总量应该会撞上 8 KB 上限');
      // 被拒绝的那条不能留在内存里，也不能留在文件里
      expect(store.usedBytes, lessThanOrEqualTo(MemoryStore.byteBudget));
      final onDisk = jsonDecode(stateJson().readAsStringSync()) as Map;
      expect((onDisk['entries'] as List).length, store.count,
          reason: '磁盘条目数与内存不一致 = 写进去了半份或者回滚没生效');
    });

    test('总开关关着时也照样守预算（重新打开要能一次写完）', () async {
      await store.setEnabled(false);
      var rejected = false;
      for (var i = 0; i < 12; i++) {
        final err = await store.add('第$i条${'字' * 500}');
        if (err != null) {
          rejected = true;
          break;
        }
      }
      expect(rejected, isTrue, reason: '关掉注入不等于可以超预算');
      expect(store.usedBytes, lessThanOrEqualTo(MemoryStore.byteBudget));
      expect(store.enabled, isFalse, reason: '被拒绝的添加不该顺手改开关');
    });

    test('空内容被拒绝', () async {
      expect(await store.add('   '), isNotNull);
      expect(store.count, 0);
    });
  });

  group('幂等与原子写', () {
    test('ensureAgentsMd 内容一致时跳过写盘（内容不变）', () async {
      await store.add('一条');
      final before = readAgents();
      final err = await store.ensureAgentsMd();
      expect(err, isNull);
      expect(readAgents(), before);
    });

    test('删掉全部记忆后 ensureAgentsMd 会把残留的块清掉', () async {
      await store.add('一条');
      // 模拟"界面说删了、文件里还留着"的旧状态：直接从 json 里清空但不走 store
      stateJson().writeAsStringSync('{"entries":[]}');
      final reloaded = MemoryStore(dshHome: dir.path);
      await reloaded.load();
      expect(reloaded.count, 0);
      await reloaded.ensureAgentsMd();
      expect(readAgents(), isNot(contains(MemoryStore.blockBegin)),
          reason: '残留的块会让模型一直看到已经删掉的内容');
    });

    test('不留 .part 残留（原子写走 rename）', () async {
      await store.add('一条');
      final leftovers = dir
          .listSync()
          .map((e) => e.path.split('/').last)
          .where((n) => n.endsWith('.part'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('memory.json 坏掉时按空处理，但**不覆盖**磁盘（用户还能自己抢救）', () async {
      stateJson().writeAsStringSync('{ 这不是 JSON');
      final s2 = MemoryStore(dshHome: dir.path);
      await s2.load();
      expect(s2.count, 0);
      expect(stateJson().readAsStringSync(), '{ 这不是 JSON',
          reason: '读失败不该顺手把用户的数据抹掉');
    });
  });

  group('i18n 锚点与枚举文案同步（改了文案必须同步锚点）', () {
    /// 源码里的锚点片段（`memoryI18nAnchors() { ... }`）。
    String anchorRegion() {
      final src = File('lib/data/memory_store.dart').readAsStringSync();
      final at = src.indexOf('void memoryI18nAnchors()');
      expect(at, greaterThan(0), reason: '找不到 memoryI18nAnchors()：锚点被改名或删掉了？');
      final open = src.indexOf('{', at);
      final close = src.indexOf('\n}', open);
      expect(close, greaterThan(open), reason: '锚点函数的括号没配对');
      return src.substring(open, close);
    }

    test('分类名 / 分类提示 / 范围名 / 重要度档位 / 来源名，全部逐字出现在锚点里', () {
      final anchors = anchorRegion();
      final fields = <String>[
        for (final k in MemoryKind.values) ...<String>[k.label, k.hint],
        for (final s in MemoryScope.values) s.label,
        for (final s in MemorySource.values) s.label,
        for (final i in <int>[1, 2, 3]) importanceLabel(i),
      ];
      for (final f in fields) {
        expect(anchors.contains(f), isTrue,
            reason: '「$f」不在 memoryI18nAnchors() 里：切到英文会露出中文，'
                '而 check-tables 仍然报 0 漂移');
      }
    });
  });
}
