/// Gemma（GGUF / llama.cpp 那条路）用的**兼容对话模板**。
///
/// ## 为什么必须有这个文件
///
/// 用户真机（2026-10-07）发什么都失败，报的是：
/// ```
/// Jinja Exception: Conversation roles must alternate user/assistant/user/assistant/...
/// ```
/// 根因（**本机用同一个 `gemma-3-1b-it-Q4_K_M.gguf` + 同版本引擎实测确证**）：
/// Gemma 自带的对话模板**只接受"首条是 system、之后严格 user/assistant 交替"**，
/// 而 **DSH 每轮都会把多条 system 段各自 push 成一条 system 消息** ——
/// 见 `pi-ai/dist/api/openai-completions.js`：
/// `const text = i === 0 ? getSystemMessageText(msg) : renderSystemMessageUpdate(msg);`
/// 于是实际发出来是 `[system, system, user]`，正好撞上 Gemma 模板第 18 行的硬校验。
///
/// 实测矩阵（同版本引擎 + 同一个模型文件）：
///
/// | 消息形状 | 官方模板 | 本文件模板 |
/// |---|---|---|
/// | `[system, user]` | 200 | 200 |
/// | `[system, system, user]` | **400** | 200 |
/// | `[system, user, user]` | **400** | 200 |
/// | `[user, user]` | **400** | 200 |
/// | `[assistant, user]` | **400** | 200 |
/// | 严格交替 | 200 | 200 |
///
/// 而且换成本文件后**多轮对话回复正常**（系统提示被正确注入：模型能自己说出
/// "我能读文件、写文件、跑命令"），带 `tools` 也正常。
///
/// ## 相对官方模板改了什么
///
/// 1. **删掉那条角色交替硬校验**（不再 `raise_exception`）；
/// 2. 首条 system 仍按官方做法并进第一个 user；
/// 3. **中途 / 多余 / 非交替的 system 一律按 user 渲染**（Gemma 对连续 user turn
///    能正常工作 —— llama.cpp 内置的 gemma 模板也是这么合并 system 的）；
/// 4. 其余（`<start_of_turn>` 结构、图片标记、生成提示）与官方保持一致。
///
/// ⚠️ **只给 Gemma 家族用**：它写死了 `<start_of_turn>` 格式，套到 Qwen 那类
/// 模型上会答非所问。判断见 [needsLooseChatTemplate]。
library;

/// 兼容模板源码。**原样交给 `--chat-template`**
/// （llama.cpp 的 `--chat-template` 接受模板**源码**，不只是内置名）。
///
/// ⚠️ 改动这个字符串等于改模型看到的对话格式，改完必须重新做一遍上面那张矩阵的实测。
const String kLooseGemmaTemplate = r'''
{{ bos_token }}
{%- set loop_messages = messages -%}
{%- set first_user_prefix = "" -%}
{%- if loop_messages and loop_messages[0]['role'] == 'system' -%}
    {%- if loop_messages[0]['content'] is string -%}
        {%- set first_user_prefix = loop_messages[0]['content'] + '

' -%}
    {%- else -%}
        {%- set first_user_prefix = loop_messages[0]['content'][0]['text'] + '

' -%}
    {%- endif -%}
    {%- set loop_messages = loop_messages[1:] -%}
{%- endif -%}
{%- for message in loop_messages -%}
    {%- if message['role'] == 'assistant' -%}
        {%- set role = "model" -%}
    {%- else -%}
        {%- set role = "user" -%}
    {%- endif -%}
    {{ '<start_of_turn>' + role + '
' + (first_user_prefix if loop.first else "") }}
    {%- if message['content'] is string -%}
        {{ message['content'] | trim }}
    {%- elif message['content'] is iterable -%}
        {%- for item in message['content'] -%}
            {%- if item['type'] == 'image' -%}
                {{ '<start_of_image>' }}
            {%- elif item['type'] == 'text' -%}
                {{ item['text'] | trim }}
            {%- endif -%}
        {%- endfor -%}
    {%- endif -%}
    {{ '<end_of_turn>
' }}
{%- endfor -%}
{%- if add_generation_prompt -%}
    {{'<start_of_turn>model
'}}
{%- endif -%}
''';

/// 这个模型要不要**直接**换用兼容模板。
///
/// 判据用"家族名或文件名含 gemma"（而不是清单 id）：用户自己导入的 GGUF
/// 文件名千奇百怪，但 Gemma 的模型名基本都会带 gemma。
///
/// ⚠️ **刻意排除 `gemma-4`**：Gemma 4 的对话模板是**另一套格式**
/// （llama.cpp 为它单写了 `gemma4` 解析器，tool call 用 `<|tool_call>call:`），
/// 把 Gemma 3 的 `<start_of_turn>` 模板套上去很可能答歪 —— **这个不能赌**。
/// 所以只对"已知模板写死了严格交替"的 Gemma 3 及更早下药；Gemma 4 保持用它自带的
/// 模板 —— 它要真坏的话，**启动自检**会在界面上给一行红字，届时再处理。
bool needsLooseChatTemplate({
  required String family,
  required String fileName,
}) {
  final name = '$family $fileName'.toLowerCase();
  if (!name.contains('gemma')) return false;
  if (name.contains('gemma-4') || name.contains('gemma4')) return false;
  return true;
}
