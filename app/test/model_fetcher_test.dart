/// 「拉回来的模型列表怎么解析」的单元测试。
///
/// ## 为什么专门盯这一段
///
/// 它坏掉的表现**不是报错**，而是：
///   * 界面上"模型名字"显示成内部 id（真机反馈 2026-10-15：「模型名字也不对」）；
///   * 或者列表里少了一批模型（同一批反馈：「没有读取出全部模型」）；
///
/// 两种情况下日志都一切正常 —— 这正是它一直没被测试盯住的缘故。
/// 解析要容忍多种真实存在的返回形态，所以这里**逐种喂一遍**。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/data/model_fetcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('OpenAI 形态：name 必须被当成显示名（真机报过"名字不对"）', () {
    final list = parseModelList('{"object":"list","data":['
        '{"id":"deepseek-chat","name":"DeepSeek 对话"},'
        '{"id":"deepseek-reasoner","object":"model"}'
        ']}');
    expect(list.length, 2);
    expect(list[0].id, 'deepseek-chat');
    expect(list[0].label, 'DeepSeek 对话',
        reason: '接口给了 name 就该拿它当显示名 —— 以前这里回落成 id，'
            '用户看到的就是"模型名字不对"');
    expect(list[1].label, 'deepseek-reasoner', reason: '没有名字时回落 id，这是对的');
  });

  test('display_name 仍然优先于 name', () {
    final list =
        parseModelList('{"data":[{"id":"m","name":"N","display_name":"D"}]}');
    expect(list.single.id, 'm');
    expect(list.single.label, 'D');
  });

  test('只有 name 的形态：id 与显示名都取它', () {
    final list = parseModelList('{"data":[{"name":"only-name"}]}');
    expect(list.single.id, 'only-name');
    expect(list.single.label, 'only-name');
  });

  test('字符串数组 / models 键 / 顶层数组三种形态都能解析', () {
    expect(parseModelList('{"data":["a","b"]}').map((e) => e.id).toList(),
        <String>['a', 'b']);
    expect(parseModelList('{"models":["c"]}').single.id, 'c');
    expect(parseModelList('["d"]').single.id, 'd');
    expect(parseModelList('{"result":["e"]}').single.id, 'e');
  });

  test('同 id 只留一条；空 id / 空 name 丢掉', () {
    final list = parseModelList(
        '{"data":[{"id":"a"},{"id":"a"},{"id":""},{"name":"   "}]}');
    expect(list.length, 1);
    expect(list.single.id, 'a');
  });

  test('context_length 兼容数字与字符串两种写法', () {
    final list = parseModelList(
        '{"data":[{"id":"a","context_length":4096},{"id":"b","context_window":"8192"}]}');
    expect(list[0].contextLength, 4096);
    expect(list[1].contextLength, 8192);
  });

  test('input_modalities 里的 image 会被认出来（deepseek-flash 就是视觉模型）', () {
    // 用户 2026-10-16 问「deepseek 还有个视觉模型，为什么不抓」：
    // 官方 `/models` 里 `deepseek-flash` 的 `input_modalities` = ["text","image"]
    // —— **视觉能力就是并进它里面的**，不是第 3 个模型。以前我们没解析这一项，
    // 于是界面上根本看不出哪个能看图。
    final list = parseModelList('{"data":['
        '{"id":"deepseek-flash","name":"DeepSeek-V4.1-Flash","input_modalities":["text","image"]},'
        '{"id":"deepseek-v4-pro","name":"DeepSeek-V4-Pro","input_modalities":["text"]}'
        ']}');
    expect(list[0].acceptsImage, isTrue,
        reason: 'flash 的输入含 image —— 它就是 DeepSeek 现在的视觉模型');
    expect(list[1].acceptsImage, isFalse, reason: 'v4-pro 只吃文本');
    // 没给这个字段的厂家 → 不算支持（宁可不标，别乱标）
    final none = parseModelList('{"data":[{"id":"x"}]}');
    expect(none.single.acceptsImage, isFalse);
  });

  test('supported_endpoints 会被取出来（界面上用它标"可能调不通"）', () {
    final list = parseModelList(
        '{"data":[{"id":"a","supported_endpoints":["/v1/messages"]}]}');
    expect(list.single.supportedEndpoints, <String>['/v1/messages']);
  });

  test('结构不认识 → 返回空列表（由调用方去报"没解析出模型"）', () {
    expect(parseModelList('{"data":{"nested":[]}}'), isEmpty);
    expect(parseModelList('{}'), isEmpty);
    expect(parseModelList('123'), isEmpty);
  });

  test('不是 JSON → 抛（调用方会翻成人话，不假装"零个模型"）', () {
    expect(() => parseModelList('not json at all'), throwsFormatException);
  });
}
