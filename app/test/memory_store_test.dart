/// 「用户记忆」的测试。
///
/// ## 这一组为什么必须存在
///
/// 记忆这条链路的失效方式**全是静默的**：写错了不会崩、界面照常显示，
/// 但模型看不到（或看到**已经删掉的内容**）。而且它和「专家」开关**共用同一个文件**
/// `$DSH_HOME/AGENTS.md` —— 两个写者互相覆盖是最可能的事故，必须钉住。
///
/// 覆盖：块读写 / 与专家块共存（双向）/ 块**前置**（截断先砍尾部）/ 标记注入 /
/// 预算回滚（不留半份）/ 删除同步 / 幂等 / 原子写不留 .part / 坏 JSON 不覆盖磁盘。
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
}
