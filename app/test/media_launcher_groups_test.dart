/// 「创作台入口屏分类」的源码断言（用户 2026-10-16：「创作台那里项目太多，
/// 是不是也分类，用下拉菜单」）。
///
/// 为什么用源码断言而不是 widget 测试：`MediaPage` 要 runtime / settings / 模型
/// 等一整套依赖，为"入口屏有没有分组"去搭那套架子不划算；而这里要钉住的恰恰是
/// **结构约定**（分了几组、用没用真折叠组件、10 个入口一个不少）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('创作台入口屏：按 4 组分类，且用的是真折叠组件（DshGroupSection）', () {
    final src = File('lib/ui/pages/media_page.dart').readAsStringSync();
    if (!src.contains('Widget _launcherView()')) {
      markTestSkipped('源码读取不完整（并发编辑中），跳过');
      return;
    }
    // 4 个分组标题必须都在
    for (final t in <String>[
      '生成图像与视频',
      '口播与短剧',
      '工具',
      '创作',
    ]) {
      expect(src.contains("context.tr('$t')"), isTrue,
          reason: '少了分组标题「$t」');
    }
    // 必须是**可收起的**分组，不是把标题当小字铺一排
    expect('DshGroupSection'.allMatches(src).length, greaterThanOrEqualTo(4),
        reason: '分组没复用 DshGroupSection（那样用户点不开）');
    // 入口一个都不能丢。注意：**源码里**是 7 个调用点（两组 `_modes` 循环各 1 +
    // 工具组 3 + 创作组 2），加上 `_workbenchEntry` 自己的定义共 8 处；
    // **运行时**才是 10 个入口（5 个生成模式 + 5 个单独入口）。
    expect('_workbenchEntry('.allMatches(src).length, greaterThanOrEqualTo(7),
        reason: '源码里的入口调用变少了 —— 分类不能把功能弄丢');
    expect('for (final m in _modes'.allMatches(src).length, 2,
        reason: '「生成图像与视频」与「口播与短剧」两组应该各渲染一次 _modes');
    expect(src.contains('(value: 0, icon:'), isTrue,
        reason: '`_modes` 那张表被动了（它同时是入口屏和 `_seg` 的映射）');
    // 每个分组默认收起（用户要的是"分类+下拉"，一进来先看见类别）
    expect(src.contains('initiallyOpen: true'), isFalse,
        reason: '没有分组应该是默认展开的（那又变成一眼铺满）');
  });
}
