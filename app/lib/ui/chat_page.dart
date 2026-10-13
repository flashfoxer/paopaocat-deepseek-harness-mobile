/// 旧路径的转发文件。
///
/// 重做界面时对话页搬到了 `ui/pages/chat_page.dart`（按"页面 / 组件 / 主题"
/// 分层）。保留这个文件是为了让 `import 'ui/chat_page.dart'` 这种旧引用
/// 仍然有效 —— 少一个"改了路径就编译不过"的坑。
///
/// 新代码请直接 import `pages/chat_page.dart`。
library;

export 'pages/chat_page.dart';
