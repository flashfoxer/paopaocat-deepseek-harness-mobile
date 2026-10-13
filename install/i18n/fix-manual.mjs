#!/usr/bin/env node
// 第二轮收尾：处理替换器没法自动判断的几处（上下文缺失、编译期常量、switch case）。
import fs from 'node:fs';

const fixes = [
  // models.dart 全文没有 import 段（只有 library;），add-imports 跳过了它
  { file: 'lib/protocol/models.dart', guard: 'i18n/dsh_i18n.dart',
    from: 'library;\n', to: "library;\n\nimport '../i18n/dsh_i18n.dart';\n" },
  // 局部 const map 里调 tr()：常量表达式不能调函数
  { file: 'lib/protocol/models.dart', from: '    const names = {', to: '    final names = {' },
  // _fill 的签名漏改，和 translate 的 List<Object?>? 对不上
  { file: 'lib/i18n/dsh_i18n.dart', from: '_fill(String s, List<Object>? args)', to: '_fill(String s, List<Object?>? args)' },
  // _ChatPageState 里的 static 方法用不了 State.context → 去掉 static
  { file: 'lib/ui/pages/chat_page.dart',
    from: '  static String? _permissionKindLabel(String? kind) {',
    to: '  String? _permissionKindLabel(String? kind) {' },
  // customPendingNote 已 getter 化，不再是编译期常量
  { file: 'lib/ui/pages/settings_tab.dart',
    from: '        const SnackBar(content: Text(AppSettings.customPendingNote)),',
    to: '        SnackBar(content: Text(AppSettings.customPendingNote)),' },
  // 顶层函数没有 context
  { file: 'lib/ui/pages/workspace_page.dart',
    from: "  final live = sessions.any((s) => s.live) ? context.tr(' · 含本次运行') : '';\n  return context.tr('{0} 个会话{1}', [sessions.length, live]);",
    to: "  final live = sessions.any((s) => s.live) ? tr(' · 含本次运行') : '';\n  return tr('{0} 个会话{1}', [sessions.length, live]);" },
  // 纯字符串工具函数，不需要上下文
  { file: 'lib/ui/widgets/send_log_button.dart', all: true, from: "context.tr('未知')", to: "tr('未知')" },
  // light/dark 已 getter 化，const 列表装不下
  { file: 'lib/ui/theme/dsh_palette.dart',
    from: '  static const List<DshPalette> all = <DshPalette>[light, dark];',
    to: '  static List<DshPalette> get all => <DshPalette>[light, dark];' },
  // State 有 context，实例 getter 即可
  { file: 'lib/ui/pages/library_page.dart',
    from: "  static const _tabs = [context.tr('最近'), context.tr('我的资料')];",
    to: "  List<String> get _tabs => [context.tr('最近'), context.tr('我的资料')];" },
  // 字段初始化器不能用 context → late 推迟到首次访问（此时已能拿到）
  { file: 'lib/ui/pair_page.dart',
    from: "  final _nameController = TextEditingController(text: context.tr('我的手机'));",
    to: "  late final _nameController = TextEditingController(text: context.tr('我的手机'));" },
  // StatelessWidget 的实例方法没有 context → 显式传入
  { file: 'lib/ui/sessions_page.dart',
    from: '  String _subtitle(BridgeState state) {',
    to: '  String _subtitle(BuildContext context, BridgeState state) {' },
  { file: 'lib/ui/sessions_page.dart', from: '              _subtitle(state),', to: '              _subtitle(context, state),' },
];

let ok = 0, skipped = 0;
const miss = [];
for (const f of fixes) {
  let src = fs.readFileSync(f.file, 'utf8');
  if (f.guard && src.includes(f.guard)) { skipped++; continue; }
  if (!src.includes(f.from)) { miss.push(`${f.file}  ← ${JSON.stringify(f.from.slice(0, 58))}`); continue; }
  src = f.all ? src.split(f.from).join(f.to) : src.replace(f.from, f.to);
  fs.writeFileSync(f.file, src);
  ok++;
}

// ── 附件菜单：内部 label 恢复成**中文常量**，只在显示时 tr。
//    理由：`_showAttachHint` 用 switch(label) 分支，而 case 必须是编译期常量，
//    tr() 是运行时查表 —— 把 key 保持在数据里，两边就都成立。
{
  const f = 'lib/ui/widgets/message_stream.dart';
  let src = fs.readFileSync(f, 'utf8');
  const before = src;
  src = src.replace(/label: context\.tr\('([^']+)'\)/g, "label: '$1'");
  src = src.replace('                    label: item.label,\n', '                    label: context.tr(item.label),\n');
  src = src.replace('                  item.label,\n', '                  context.tr(item.label),\n');
  if (src !== before) { fs.writeFileSync(f, src); ok++; }
}

// ── chat_page：switch 的 case 回到中文常量
{
  const f = 'lib/ui/pages/chat_page.dart';
  let src = fs.readFileSync(f, 'utf8');
  const before = src;
  src = src.replace(/case context\.tr\('([^']+)'\):/g, "case '$1':");
  src = src.replace(/label == context\.tr\('([^']+)'\)/g, "label == '$1'");
  if (src !== before) { fs.writeFileSync(f, src); ok++; }
}

console.log(`应用 ${ok} 处 · 跳过（已改） ${skipped} 处`);
if (miss.length) { console.log('❌ 没匹配到：'); miss.forEach((m) => console.log('   ' + m)); }
