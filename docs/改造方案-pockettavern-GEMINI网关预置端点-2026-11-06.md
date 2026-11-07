# 改造方案：pockettavern 预置端点「GEMINI网关」

> 日期：2026-11-06
> 状态：开发交付稿
> 目标版本：pockettavern v1.14.0（`pubspec.yaml` 当前 `1.13.1+119`）
> 代码基线：HEAD `4585748b`，**加上工作区未提交修改**（`llm_backend.dart`、`llm_backends.dart`、`chat_provider_local.dart` 等 20 余个文件）。开发前先确认这些修改已提交或已合入，再按本文改动；本文引用的行号基于 2026-11-06 的工作区内容。
> 依赖文档：
> - [产品设计-Gemini额度路由网关-2026-11-06.md](./产品设计-Gemini额度路由网关-2026-11-06.md)（“内核文档”）
> - [产品设计-eatgemini桌面单文件版-2026-11-06.md](./产品设计-eatgemini桌面单文件版-2026-11-06.md)（“桌面文档”）
> 范围：**本地模式**（App 直连网关）。远程模式（经 SillyTavern 中转）见 §11，不在 v1.14.0 必做范围。

---

## 一、目标

1. 连接档案页固定显示一个预置端点 **GEMINI网关**，用户不需要选协议、不需要手输模型名，只填地址和访问令牌（或粘贴连接码）即可使用。
2. GEMINI网关使用独立的 `GeminiGatewayBackend`：
   - 请求体按白名单构造，不把其他服务商的专有参数发给网关；
   - 严格判断流是否完整结束，网关中途断开时**不再把半截回复当成正常完成**；
   - 解析网关的结构化错误，用中文说明原因和恢复时间。
3. 档位（`router:chat` / `router:fast` / `router:quality`）从网关 `/v1/models` 读取，可选具体模型。
4. 能看到本轮实际由哪个模型回答、网关额度状态。
5. 连接测试**不消耗生成额度**。

### 不做

- 不把网关内核内置进 App（内核文档 §11.7 的可选项另行评估）。
- 不改通用 `OpenAiCompatibleBackend` 的行为（它的 EOF 问题见 §12 的后续建议，单独排期）。
- Google API Key 永远不进手机。手机只持有网关下发的 `egw_pt_` 访问令牌。
- 不自动修改 SillyTavern 服务端配置。

---

## 二、现状核对（决定改法的代码事实）

| 位置 | 现状 | 对 GEMINI网关 的影响 |
|---|---|---|
| `lib/core/llm/connection_profile.dart:77` | `ProfileKind` 只有 `openaiCompatible`、`anthropic`；`fromKey` 未知值回落 `openaiCompatible` | 新增枚举值后，旧版 App 读到新档案会当 OpenAI 兼容处理，降级可用 |
| `connection_profile.dart:157` | 档案存 SharedPreferences `llm_profiles_v1`，Key 存 secure storage `llm_key_<id>` | 预置档案沿用同一套存储，固定 id |
| `lib/core/llm/local_llm_config.dart:99` | 有激活档案时：`source` 为 `custom` 或 `claude`，`headers` 为空 | 需要新分支，`source = 'gemini_gateway'` |
| `lib/presentation/providers/chat_provider_local.dart:343` | 后端选择写死三元表达式（Anthropic / OpenAI），没走 `backendFor()` | 改为 `backendFor(cfg.kind)` |
| `chat_provider_local.dart:361` | 思考参数一律按 `source: 'custom'` 编译 | 网关档案需要专用编译（§7.3），否则别名 `router:chat` 落到“未识别模型”，什么都不发；或旧档案的 `enable_thinking` 等专有块被带上 |
| `chat_provider_local.dart:416–433` | `extraBody` 原样带上 `frequency_penalty/presence_penalty/top_k/min_p/top_a/repetition_penalty/seed/logit_bias/max_completion_tokens` 与思考块 | 网关对未知字段返回 400（内核文档 §12），`min_p/top_a/repetition_penalty` 会让每次请求失败 |
| `lib/core/llm/llm_backends.dart:63` | `buildBody` 固定 `stream:true`、`include_usage:true`，`...req.extraBody` 原样并入 | 网关后端必须有自己的 `buildBody` |
| `llm_backends.dart:250` `sseFrames()` | 按行取 `data:`；自然 EOF 后 `generate()` 直接 `yield done`；JSON 解析失败 `continue` | 网关中途断开会被当成完成（内核文档 §11.3 已记录）；网关后端改用严格解码器 |
| `llm_backends.dart:313` `describeLlmError` | 只返回 `HTTP <code>：<message>` 字符串 | 丢失 `error.code`、`retry_after_seconds`、`request_id` |
| `lib/core/llm/llm_probe.dart:75` `probeLlmEndpoint` | `/models` 失败后会发一条 `max_tokens=1` 的真实生成请求 | 对网关来说会消耗一次 RPD 额度，网关档案不能用它 |
| `chat_provider_local.dart:446–563` | 空正文自愈：`finish_reason == 'length'` 且只有思考时，加大 `max_tokens` 再请求一次 | 对网关是第二次真实生成，保留但要计入统计（§7.6） |
| `lib/presentation/providers/chat_provider_vectors.dart:123` `_summaryViaDirectLlm` | 摘要旁路复用同一配置；遇到 `chunk.error` 时 `break` 后返回已拼接的半截文本 | 摘要也消耗网关额度；出错时半截摘要会被写入 `chat_metadata.summary`（§9.1 修复） |
| `lib/presentation/providers/context_budget_provider.dart:69` | 本地模式 `GET {base}/models` 读取 `context_window` / `max_output_tokens` | 网关 `/v1/models` 已按桌面文档 §10.2 输出这两个字段，无需改动 |
| `lib/presentation/providers/request_pipeline.dart:244` `RequestBuild.compatibilityWarnings` | 已有兼容提示列表，在“本次发送详情”展示；但它在发送前构建、不可变 | 网关后端丢弃的参数另存于 `lastGatewayTrace.notes`（§7.5），在同一详情页展示 |
| `chat_provider_generate.dart:641` | 出错时若已有正文，保留消息并标记错误卡片 | 流不完整按错误上报即可保留半截正文，无需改消息逻辑 |
| `android/app/src/main/AndroidManifest.xml:8` | `usesCleartextTraffic="true"` | 局域网 `http://` 可用，无需改 |

---

## 三、整体方案

```text
设置 → AI 服务 → 连接档案
  ├─ [预置] GEMINI网关   ← 新增，固定置顶，不可删除
  └─ 用户自建档案…

激活 GEMINI网关 后，本地模式生成链路：
chat_provider_local
  → LocalLlmConfig(source: 'gemini_gateway', kind: ProfileKind.geminiGateway)
  → backendFor(kind) = GeminiGatewayBackend
       buildBody（白名单） → POST {base}/chat/completions（stream）
       GatewaySseDecoder（严格 SSE） → LlmChunk（含完成状态、错误码、实际模型）
  → 现有消息落盘、计费、统计逻辑
```

与网关的契约（全部由桌面文档定义，本文只消费）：

| 接口 | 用途 | 定义位置 |
|---|---|---|
| `GET /healthz`（无鉴权） | 地址探测、识别是不是 eatgemini、`api` 版本 | 桌面文档 §10.1 |
| `GET /v1/models` | 档位与模型列表、上下文上限 | 内核文档 §10、桌面文档 §10.2 |
| `GET /router/status` | 额度状态、可用思考档位 | 桌面文档 §10.3 |
| `POST /v1/chat/completions` | 生成，`stream:true` | 内核文档 §8、§10、§12 |
| 错误 envelope 与错误码 | 错误映射 | 内核文档 §10、桌面文档 §10.4 |
| 连接码 `egw1:` | 一次性填好地址/令牌/模型 | 桌面文档 §10.6 |
| 响应头 `X-Router-Model`、`X-Router-Attempts`、`X-Request-Id`（请求带 `X-Router-Trace: 1`） | 实际模型、尝试次数、请求 ID | 内核文档 §10 |

客户端支持的契约版本：`api == 1`。`/healthz` 返回更大的值时，配置页提示“网关版本较新，建议升级 pockettavern”，但不阻止使用。

---

## 四、数据模型

### 4.1 `ProfileKind`

`lib/core/llm/connection_profile.dart`：

```dart
enum ProfileKind {
  openaiCompatible,
  anthropic,
  geminiGateway;

  String get storageKey => name;

  String get label => switch (this) {
        ProfileKind.openaiCompatible => 'OpenAI 兼容',
        ProfileKind.anthropic => 'Anthropic',
        ProfileKind.geminiGateway => 'GEMINI网关',
      };

  static ProfileKind fromKey(String k) => switch (k) {
        'anthropic' => ProfileKind.anthropic,
        'geminiGateway' => ProfileKind.geminiGateway,
        _ => ProfileKind.openaiCompatible,
      };
}
```

所有 `switch (kind)` 和 `kind == ProfileKind.anthropic ? … : …` 的调用点都要检查一遍（`grep -rn "ProfileKind" lib` 共 7 个文件），确认 `geminiGateway` 走 OpenAI 系路径（`/models`、`Authorization: Bearer`），除非本文另有规定。

### 4.2 预置档案

新文件 `lib/core/llm/gemini_gateway.dart`：

```dart
const String kGeminiGatewayProfileId = 'builtin-gemini-gateway';
const String kGeminiGatewayName = 'GEMINI网关';
const String kGeminiGatewayDefaultModel = 'router:chat';
const String kGeminiGatewayEmulatorBaseUrl = 'http://10.0.2.2:8787/v1/';
const int kGeminiGatewayApiVersion = 1;

bool isGeminiGatewayProfile(ConnectionProfile p) =>
    p.id == kGeminiGatewayProfileId;
```

- 预置档案是一个普通的 `ConnectionProfile`：`id = kGeminiGatewayProfileId`、`kind = geminiGateway`、`name = 'GEMINI网关'`、`model` 默认 `router:chat`。不新增字段，`temperature/topP/maxTokens` 保持默认值（本地生成链路不读这几个字段）。
- **未配置时不写入档案库。** 连接档案页的预置卡片在档案库里没有这个 id 时显示“未配置”占位（§5.1）。用户第一次在配置页保存后才 `add()` 进档案库。这样 `localReadyProvider` 不会因为一个空档案误判“已就绪”。
- 访问令牌存 `LlmKeyStore`，key 为 `llm_key_builtin-gemini-gateway`，沿用现有加密存储与启动预热（`main.dart:29` 已对档案库中所有 id 预热）。
- 预置档案**不能删除**，只能“清除配置”：从档案库移除并删除令牌（复用 `ConnectionProfiles.remove`），预置卡片回到“未配置”。用户名称不可改。

### 4.3 网关状态缓存

新 provider（`lib/presentation/providers/gemini_gateway_provider.dart`）：

```dart
/// 当前激活的 GEMINI网关 的 /router/status，缓存 5 分钟。
/// 非网关档案或请求失败时为 null；失败不抛给 UI。
final geminiGatewayStatusProvider =
    FutureProvider.autoDispose<GatewayStatus?>((ref) async { … });
```

- `GatewayStatus` 为 `/router/status` 的强类型解析结果（字段见桌面文档 §10.3），解析器容忍缺失字段、忽略未知字段。
- 触发时机：激活网关档案时、进入额度面板时、配置页测试成功时；之后 5 分钟内复用。
- 思考参数编译（§7.3）是同步的，只读这个 provider 的**已有值**（`ref.read(...).valueOrNull`），不等待网络。

---

## 五、界面

### 5.1 连接档案页（`connection_profiles_screen.dart`）

列表改为两段：

```text
预置端点
┌──────────────────────────────────────────────┐
│ ◉ GEMINI网关                         [启用中] │
│   router:chat · 192.168.1.23:8787            │
│   通过电脑上的 eatgemini 使用 Gemini 免费额度   │
│                         [额度状态] [配置] [⋮] │
└──────────────────────────────────────────────┘
我的档案
  ○ 官方 API · OpenAI 兼容 · gpt-4o-mini
  …
```

| 预置卡片状态 | 副标题 | 按钮 |
|---|---|---|
| 未配置（档案库无此 id） | “通过电脑上的 eatgemini 使用 Gemini 免费额度” | [配置] |
| 已配置、未启用 | `<模型> · <host:port>` | [启用] [配置] [⋮] |
| 已启用 | 同上，标签“启用中” | [额度状态] [配置] [⋮] |

- 菜单 [⋮]：启用、配置、额度状态、清除配置（二次确认“会删除保存的访问令牌”）。没有“删除”“编辑名称”。
- 点卡片主体：已配置则启用；未配置则进配置页。
- 右下角“新增档案”的编辑表单（`_ProfileEditSheet`）中**不出现** `geminiGateway` 选项，避免用户手动建出第二个网关档案。若档案库中出现 `kind == geminiGateway` 但 id 不是预置 id 的档案（例如未来导入），按普通档案显示并可删除。

### 5.2 GEMINI网关 配置页（新文件 `gemini_gateway_setup_screen.dart`）

全屏页面，自上而下：

1. **说明**（可折叠）：“GEMINI网关 由电脑上的 eatgemini 程序提供。Google API Key 只保存在电脑上，手机只需要 eatgemini『接入』页给出的地址和访问令牌。”
2. **粘贴连接码**：输入框 + “从剪贴板粘贴”按钮。解析成功（§5.3）后自动填入下面三项，并立即执行“测试连接”。解析失败提示“连接码无效，请在 eatgemini『接入』页重新复制”。
3. **网关地址**：输入框。
   - 提示文字：“真机：电脑的局域网地址，如 `http://192.168.1.23:8787/v1`；模拟器：`http://10.0.2.2:8787/v1`”。
   - 快捷按钮“模拟器地址”。
   - 保存时用现有 `normalizeLlmBaseUrl(raw, isPrivateHost: isPrivateHost)` 规范化；路径不以 `/v1` 结尾时自动补 `/v1/`（用户常漏写），并在输入框下方显示规范化后的地址。
4. **访问令牌**：遮挡输入框 + 显示切换。
   - 以 `AIza` 开头时阻止保存：“这是 Google API Key，请填 eatgemini 生成的访问令牌（以 egw_pt_ 开头）。Google Key 只需要填在电脑上。”
   - 不以 `egw_` 开头时提示“看起来不是 eatgemini 的访问令牌”，可继续。
5. **档位**：下拉框。
   - 测试成功前固定提供：`router:chat`（均衡，默认）、`router:fast`（偏快）、`router:quality`（只用较强模型，用完即报错）、`auto`。
   - 测试成功后用 `/v1/models` 的结果替换：先列 `router:*` 与 `auto`（附上面的中文说明），再在“固定模型”分组列具体模型 ID，附说明“固定模型不会自动换模型，额度用完直接报错”。
   - 当前值不在列表中时保留并标黄“网关未提供此模型”。
6. **测试连接**按钮（§5.4），结果内联显示。
7. 底部：[保存] [保存并启用]。保存时：`ConnectionProfiles.add/update` + `LlmKeyStore.write`；“保存并启用”再 `setActive(kGeminiGatewayProfileId)`。

### 5.3 连接码解析

`lib/core/llm/gemini_gateway.dart`：

```dart
class GatewayConnectCode {
  final List<String> urls;
  final String token;
  final String model;
  final String name;
}

/// 解析 `egw1:` 连接码；格式错误返回 null，不抛异常。
GatewayConnectCode? parseGatewayConnectCode(String raw);

/// 并发探测 urls 的 /healthz（每个 1.5 秒超时），
/// 返回 urls 顺序中第一个 `app == 'eatgemini'` 的地址；都失败返回 null。
Future<String?> pickReachableGatewayUrl(List<String> urls);
```

解析规则：去首尾空白 → 必须以 `egw1:` 开头 → base64url 解码（容忍缺少填充）→ UTF-8 JSON → `v == 1`、`urls` 为非空字符串数组且每项是 `http`/`https` URL、`token` 非空。任一不满足返回 null。

`pickReachableGatewayUrl` 都失败时，仍用 `urls.first` 填入地址，并显示 §5.4 的连不上排查清单。

### 5.4 测试连接（不耗额度）

新函数 `probeGeminiGateway(LlmEndpoint e)`（放 `gemini_gateway.dart`），**只发 GET**：

| 步骤 | 请求 | 失败时提示 |
|---|---|---|
| 1 | `GET {origin}/healthz`，3 秒超时，`origin` 为 baseUrl 去掉路径 | 连接被拒/超时：“连不上 eatgemini：① 电脑上 eatgemini 是否在运行 ② 手机和电脑是否在同一 Wi-Fi ③ eatgemini『接入』页是否开启了局域网模式 ④ Windows 防火墙是否允许 eatgemini（专用网络）⑤ 模拟器请用 10.0.2.2” ；返回不是 `app: eatgemini`：“这个地址不是 eatgemini 网关” |
| 2 | `GET {base}/models`，带令牌，10 秒超时 | 401：“访问令牌无效，请在 eatgemini『接入』页复制新令牌”；其他：显示网关错误 message |
| 3 | `GET {origin}/router/status`，带令牌 | 失败不影响结果，只是不显示额度摘要 |

成功时显示：“连接正常 · eatgemini <version> · 可用档位 N 个”，并附额度摘要（例如“router:chat 可用（下一个模型 gemini-3.8-flash）”）。若 `/router/status` 的 `app.state == 'needs_key'`：显示黄色提示“已连上，但电脑上的 eatgemini 还没有填写 Google API Key”，测试结果仍算连接成功。

`settings_ai_screen.dart` 的 `_testConnectionLocal()` 与 `_loadModelsLocal()`：当 `cfg.kind == ProfileKind.geminiGateway` 时分别改调 `probeGeminiGateway` 与网关模型列表，**不调用** `probeLlmEndpoint`（它会在 `/models` 失败时发真实生成）。

### 5.5 额度状态面板（新文件 `gemini_gateway_status_sheet.dart`）

底部弹出面板，入口：预置卡片“额度状态”、AI 服务页“本地直连”卡片中新增的“网关额度”行（仅网关档案激活时显示）。

- 顶部：网关状态（`app.state` 中文 + `reason`）、“今日额度 <北京时间 HH:mm> 重置，还有 X 小时 Y 分”（由 `quotaDay.nextResetAt` 计算，按设备本地时区显示）。
- 档位列表：`router:chat / fast / quality` 各一行：状态（可用 / 暂时受限 · 预计 HH:mm 恢复 / 不可用）、下一个会使用的模型、可用模型数。
- 模型列表：每个模型一行，`rpd.used / rpd.limit` 进度条（`limit` 为 null 时只显示次数），状态与恢复时间。
- 底部固定说明：“数字是电脑上 eatgemini 的本地估算，以 Google AI Studio 为准。”
- 打开时立即刷新一次，之后每 10 秒刷新；下拉刷新。面板关闭即停止。**不发送任何生成请求。**

### 5.6 AI 服务页（`settings_ai_screen.dart`）

“本地直连”卡片中：

- 就绪行：网关档案激活时显示 `已就绪：GEMINI网关 · router:chat`（现有文案是 `${cfg.source} · ${cfg.model}`，`source` 为 `gemini_gateway` 时改用档案名）。
- 新增“网关额度”行，点开 §5.5 面板；副标题显示缓存中的档位状态，如“可用”“受限 · 16:00 重置”。
- 激活网关档案时，“生成配置”卡片中与生成源相关的地址/Key/模型输入对本地模式无效，沿用现有行为（档案优先），不额外改动。

### 5.7 本次发送详情（`request_info_sheet.dart`）

网关档案时在现有内容后增加“GEMINI网关”分组：

| 项 | 来源 |
|---|---|
| 请求档位 | 请求体 `model` |
| 实际模型 | 响应头 `X-Router-Model`，缺失时取首个 SSE 帧的 `model` 字段 |
| 网关尝试次数 | `X-Router-Attempts` |
| 请求 ID | `X-Request-Id`，带复制按钮，提示“在 eatgemini『请求记录』中可按此 ID 查看详情” |
| 客户端忽略的参数 | `lastGatewayTrace.notes`：§7.2 被丢弃的参数与 §7.3 的思考档位调整说明 |
| 结束状态 | 正常完成 / 输出被截断（length）/ 网关中断 / 已取消 |

---

## 六、配置解析与后端选择

### 6.1 `LocalLlmConfig.resolve`

`lib/core/llm/local_llm_config.dart` 的档案分支（当前第 99 行）增加网关分支，放在通用档案分支之前：

```dart
if (profile != null && profile.kind == ProfileKind.geminiGateway) {
  final url = normalizeGatewayBaseUrl(profile.baseUrl); // 补协议、补 /v1/
  final token = profileApiKey ?? '';
  return LocalLlmConfig(
    source: kGeminiGatewaySource, // 'gemini_gateway'
    baseUrl: url,
    model: profile.model.isEmpty ? kGeminiGatewayDefaultModel : profile.model,
    apiKey: token,
    kind: ProfileKind.geminiGateway,
    headers: const {'X-Router-Trace': '1'},
    error: url.isEmpty
        ? 'GEMINI网关还没填地址：设置 → AI 服务 → 连接档案 → GEMINI网关'
        : token.isEmpty
            ? 'GEMINI网关还没填访问令牌：在电脑上 eatgemini『接入』页复制'
            : null,
  );
}
```

- 不带现有 custom 源的 `x-opencode-session` 和 `User-Agent` 头。网关按令牌识别客户端，不看 UA（内核文档 §5）。
- `normalizeGatewayBaseUrl`：先调用现有 `normalizeLlmBaseUrl(raw, isPrivateHost: isPrivateHost)`，再在路径不以 `/v1/` 结尾时补 `v1/`。放 `gemini_gateway.dart`，单测覆盖 `192.168.1.23:8787`、`http://10.0.2.2:8787`、`http://x:8787/v1`、`http://x:8787/v1/` 四种输入。

### 6.2 `backendFor`

`lib/core/llm/llm_backends.dart:326`：

```dart
LlmBackend backendFor(ProfileKind kind) => switch (kind) {
      ProfileKind.anthropic => const AnthropicBackend(),
      ProfileKind.geminiGateway => const GeminiGatewayBackend(),
      ProfileKind.openaiCompatible => const OpenAiCompatibleBackend(),
    };
```

`chat_provider_local.dart:343` 的三元表达式改为 `backendFor(cfg.kind)`。`chat_provider_vectors.dart:149` 已经用 `backendFor`，自动生效。

---

## 七、`GeminiGatewayBackend`

新文件 `lib/core/llm/gemini_gateway_backend.dart`，继承 `LlmBackend`。复用 `llm_backends.dart` 的共享 Dio（`_sharedDio` 改为库内可见的 `sharedLlmDio`，或把网关后端放进同一个 library 的 `part` 文件；二选一，保持“绝不写共享 headers”的约束）。

### 7.1 请求

- `POST {base}/chat/completions`，`responseType: ResponseType.stream`，`cancelToken` 透传。
- 请求头：`Authorization: Bearer <egw_pt_ 令牌>`、`X-Router-Trace: 1`、`Content-Type: application/json`。不加其他头。
- 超时沿用共享 Dio：连接 10 秒、接收 5 分钟。网关总截止为 240 秒（内核文档 §6.2），早于客户端超时，因此超时错误应由网关先返回。

### 7.2 请求体白名单

`static GatewayBody buildBody(LlmRequest req)`，返回 `({Map<String, dynamic> body, List<String> dropped})`，纯函数。

| 字段 | 规则 |
|---|---|
| `model` | `req.model` |
| `messages` | 与 `OpenAiCompatibleBackend.buildBody` 相同：先 `postProcessLlmMessages(type: req.promptPostProcessing, …)`，再 `toJson()`（role / content 字符串 / name） |
| `stream` | 固定 `true` |
| `stream_options` | 固定 `{"include_usage": true}` |
| `temperature`、`top_p` | 非 null 时发送 |
| `max_tokens` | `req.maxTokens` > 0 时发送；若 `extraBody` 中有 `max_completion_tokens`，用它的值作为 `max_tokens`，**两者只发一个**（内核文档 §12） |
| `stop` | 非空时发送 |
| `reasoning_effort` | `req.reasoningEffort` 非 null 时发送（由 §7.3 产生） |
| `frequency_penalty`、`presence_penalty`、`seed`、`top_k` | `extraBody` 中有且非 null 时原样发送。中性值（0 等）由网关按 `tavern_text` 规则处理，客户端不做判断 |
| `logit_bias` | 空 Map 不发；非空 → **不发**，加入 `dropped`（“logit_bias（GEMINI网关不支持）”） |
| `min_p`、`top_a`、`repetition_penalty` | 网关不认识这些字段。值为 null、`0`（`min_p`/`top_a`）或 `1`（`repetition_penalty`）时静默不发；其他值不发并加入 `dropped` |
| 其他一切 `extraBody` 键（`thinking`、`enable_thinking`、`include_reasoning`、`chat_template_kwargs` 等） | **一律不发**，不加入 `dropped`（这些是思考编译产物，§7.3 已改为网关专用编译，正常不会出现；若出现属于调用方 bug，`assert` 报错，release 下静默丢弃） |
| `assistant_prefill` | 不发送（现有 OpenAI 兼容后端也不发，行为一致） |

`dropped` 的处理：`chat_provider_local` 在发送前调用一次 `GeminiGatewayBackend.buildBody` 取得 `dropped`，转成文案（`GEMINI网关 忽略了参数：min_p=0.05`）放进本轮 `notes` 列表，最终写入 `lastGatewayTrace.notes`（§7.5）；同一会话同一参数第一次出现时 SnackBar 提示一次。

### 7.3 思考参数

新函数（放 `gemini_gateway.dart`）：

```dart
/// 把预设的思考设置编译成网关可接受的 reasoning_effort。
/// [supported] 来自 /router/status 当前档位的 reasoningEfforts；
/// null 或空列表 = 网关没有核验数据 → 一律不发。
({String? effort, String? note}) compileGatewayThinking(
  ThinkingConfig config, {
  required List<String>? supported,
});
```

| `config.mode` | 结果 |
|---|---|
| `inherit` | 不发 |
| `off` | `supported` 含 `none` → `none`；否则不发，`note = '当前档位不支持关闭思考，已使用网关默认'` |
| `on` | 将 `config.level` 映射到 `supported` 中的值：精确匹配优先；否则按 `minimal < low < medium < high < max` 取不超过请求档位的最大可用值；都没有则取最小可用值。`budgetTokens` 不使用（网关只认档位）。映射发生变化时 `note = '思考强度 high 已按网关支持调整为 medium'` |
| `supported` 为 null/空 | 不发；mode 为 `on`/`off` 时 `note = '网关未提供该档位的思考能力信息，已使用默认'` |

`chat_provider_local.dart:361` 改为：

```dart
final isGateway = cfg.kind == ProfileKind.geminiGateway;
final compiledThinking = isGateway
    ? const CompiledThinking()
    : compileThinking(config: …, source: 'custom', …); // 原逻辑不变
String? reasoningEffort;
if (isGateway) {
  final status = _ref.read(geminiGatewayStatusProvider).valueOrNull;
  final r = compileGatewayThinking(
    _ref.read(effectivePresetProvider).thinkingConfig,
    supported: status?.profileFor(model)?.reasoningEfforts,
  );
  reasoningEffort = r.effort;
  if (r.note != null) notes.add(r.note!); // 本轮 notes，最终进入 lastGatewayTrace.notes
} else {
  // 原有 thinkBody / reasoning_effort 拆分逻辑
}
```

- `status.profileFor(model)`：`model` 为 `router:<id>` 时取对应 profile；`auto` 取 `chat`；具体模型 ID 时取 `models` 中该模型——桌面文档 §10.3 的 `models[]` 不含 `reasoningEfforts`，因此固定模型时不发思考参数。
- `thinkingRoomFloor(reqMaxTokens, thinkingOn: …)` 中的 `thinkingOn` 改为 `reasoningEffort != null && reasoningEffort != 'none'`。

### 7.4 严格 SSE 解码

新文件 `lib/core/llm/gateway_sse.dart`：

```dart
sealed class GatewaySseEvent {}
final class SseData extends GatewaySseEvent { final String data; }
final class SseDone extends GatewaySseEvent {}               // data: [DONE]
final class SseTruncated extends GatewaySseEvent {}          // EOF 时有未分发的半个事件

/// 按 SSE 规范解码：UTF-8 流式解码（跨包安全）；行以 \n、\r\n、\r 结束；
/// 以 ':' 开头的行是注释（保活），忽略；`data:` 行（去掉冒号后一个可选空格）
/// 累加，多行用 \n 连接；空行分发一个事件；event/id/retry 字段忽略。
/// 单个事件超过 1 MiB 抛 GatewayProtocolException。
Stream<GatewaySseEvent> decodeGatewaySse(Stream<List<int>> bytes);
```

`GeminiGatewayBackend.generate()` 的状态机：

```text
finishSeen = false; servedModel = 响应头 X-Router-Model
for event in decodeGatewaySse(stream):
  SseData:
    json = jsonDecode(data)            // 失败 → error(code: 'gateway_protocol', '网关返回了无法解析的数据')，结束
    json 为 Map 且含 error            → error(按 §8 映射，incomplete: 已有输出)，结束
    servedModel ??= json['model']
    解析 delta/finish_reason/usage（复用 parseOpenAiFrame、parseOpenAiUsage）
    finish_reason 非空 → finishSeen = true
    有内容/finish/usage → yield LlmChunk(...)
  SseDone:
    finishSeen ? yield done(...) : yield error('incomplete_stream')
    结束
  SseTruncated / 流自然结束:
    finishSeen ? yield done(...)       // 完成帧已到、只缺 [DONE] 或 usage：按完成处理（内核文档 §8）
               : yield error('incomplete_stream')
DioException(cancel) → yield LlmChunk(done: true)          // 与现有后端一致，由调用方的 cancelled 标记区分
DioException(其他)   → yield error(parseGatewayHttpError(e))
```

与现有 `sseFrames()` 的区别：不把非 SSE 文本拼成错误帧（非 2xx 已由 Dio 抛出）；JSON 错误不再跳过；没有完成帧的 EOF 一律报错。

### 7.5 `LlmChunk` 扩展

`lib/core/llm/llm_backend.dart` 的 `LlmChunk` 增加可选字段，现有调用方不受影响：

```dart
/// 错误码（网关 error.code / 'incomplete_stream' / 'gateway_protocol' 等）
final String? errorCode;
/// 上游给出的恢复时间（秒）
final int? retryAfterSeconds;
/// 网关请求 ID
final String? requestId;
/// 实际服务的模型（网关 X-Router-Model 或帧内 model）
final String? servedModel;
/// 网关尝试次数（X-Router-Attempts）
final int? attempts;
```

- `error` 字段仍是给用户看的完整中文文案（§8），`chat_provider_local` 现有的 `if (chunk.error != null) { streamError = chunk.error; break; }` 不需改就能工作。
- 第一个 `LlmChunk` 带 `servedModel/requestId/attempts`。`chat_provider_local` 记录到新的 `_GenResult.gatewayTrace`（`({String? servedModel, String? requestId, int? attempts, String endState, List<String> notes})`，`endState` 取 `completed` / `length` / `incomplete` / `cancelled` / `error`），再存入 `ChatState.lastGatewayTrace` 供 §5.7 展示。
- 已有正文时出错：`chat_provider_generate.dart:641` 的现有逻辑会保留正文并显示错误卡片，满足“保留半截输出、标为未完成”（内核文档 §11.3）。

### 7.6 空正文自愈与计费

- 空正文自愈（`chat_provider_local.dart:551`）保留，条件不变（`finish_reason == 'length'`、只有思考、无错误）。它会让网关多一次真实生成，`billedUsages` 已逐次记录；`incomplete_stream` 等错误时 `streamError != null`，不会触发自愈。
- 计费：`detectBillingProvider`（`llm_billing.dart:190`）对网关地址返回 null，不写 billing 字段，生成统计照常记录 token。需要显示“免费额度”时另开需求，本次不做。
- 客户端**不自动重试** 429/503：网关已经在内部换模型和重试（内核文档 §6），客户端再重试只会放大请求数（内核文档 §6.2 末条）。

---

## 八、错误映射

### 8.1 解析

`parseGatewayHttpError(DioException e)`（放 `gemini_gateway.dart`）：

1. 读响应体字节流（与 `describeLlmError` 相同方式解码），解析 `{"error": {message, type, code, param, request_id, retry_after_seconds}}`。
2. `retry_after_seconds` 缺失时读 `Retry-After` 响应头（秒数）。
3. `request_id` 缺失时读 `X-Request-Id` 响应头。
4. 返回 `GatewayError(httpStatus, code, message, param, retryAfterSeconds, requestId)`；解析不出 envelope 时 `code = null`，`message` 为截断到 200 字的原文。

`GatewayError.describe(DateTime now)` 生成给用户看的文案。所有文案末尾在有 `requestId` 时追加 `（请求 ID：req_xxx）`。

### 8.2 文案表

| HTTP | `error.code` | 显示文案 |
|---|---|---|
| 401 | `invalid_client_token` 或其他 | GEMINI网关 访问令牌无效。请在电脑上 eatgemini 的「接入」页复制新令牌，填到 设置 → 连接档案 → GEMINI网关 |
| 429 | `router_quota_unavailable` | 当前档位的 Gemini 模型额度都暂时用完了。`retry ≤ 120 秒`：「约 N 秒后可重试」；更长：「预计 HH:mm 恢复」；未知：「恢复时间未知，每日额度在北京时间 HH:mm 重置」（取缓存的 `/router/status` 的 `nextResetAt`；没有缓存时写「太平洋时间午夜」） |
| 429 | `auth_rate_limited` | 访问令牌错误次数过多，已被网关暂时锁定，请稍后再试 |
| 429 | 其他 | 网关繁忙（同时请求过多），请稍后重试 |
| 400 | 任意 | 请求被网关拒绝：`<message>`。`param` 非空时追加「（参数 `<param>`）」 |
| 404 | 任意 | 网关没有模型「`<model>`」，请在 GEMINI网关 配置页重新选择档位 |
| 413 | 任意 | 请求内容过大（角色卡、世界书或历史太长），超过网关的大小上限。可在电脑上 eatgemini 设置中调大上限，或减少上下文 |
| 502 | 任意 | 电脑上 eatgemini 调用 Google 失败：`<message>`。请在电脑上检查 Google API Key 和网络 |
| 503 | `gateway_needs_key` | 电脑上的 eatgemini 还没有填写 Google API Key |
| 503 | 其他 | GEMINI网关 暂时不可用：`<message>` |
| 504 | 任意 | 网关等待 Gemini 响应超时，请重试 |
| — | `incomplete_stream` | 回复在中途中断（网关连接断开或上游出错），已保留收到的部分 |
| — | `gateway_protocol` | 网关返回了无法解析的数据，请升级 eatgemini 或 pockettavern |
| — | 连接被拒 / 连接超时 / DNS | 连不上 GEMINI网关（`<host:port>`）。请确认电脑上 eatgemini 正在运行、手机和电脑在同一 Wi-Fi、eatgemini 已开启局域网模式 |
| — | 接收超时 | 等待网关响应超时（5 分钟） |

SSE 中途收到的 `{"error": …}` 帧按同一张表映射（没有 HTTP 状态时按 `code` 匹配，匹配不到用「生成中断：`<message>`」）。

---

## 九、其他调用点

### 9.1 摘要旁路（`chat_provider_vectors.dart:150`）

现状：遇到 `chunk.error` 只 `break`，随后返回已拼接的文本，半截摘要会被当作有效摘要写入 `chat_metadata.summary`。改为：

```dart
await for (final chunk in backend.generate(req)) {
  if (chunk.error != null) return '';   // 失败不产出摘要，下次再试
  if (chunk.text.isNotEmpty) buf.write(chunk.text);
  if (chunk.done) break;
}
```

这一处对所有后端都生效，属于顺手修复的缺陷，单独一条测试覆盖。摘要请求同样消耗网关额度：GEMINI网关 激活且开启了自动总结时，AI 服务页“网关额度”行的副标题下方加一行灰字“自动总结也会使用网关额度”。

### 9.2 上下文预算（`context_budget_provider.dart`）

无需改动。本地模式已按 `GET {base}/models` 匹配 `id == model` 并读取 `context_window` / `max_output_tokens`；网关对路由别名只在所有候选都已核验时输出这两个字段（桌面文档 §10.2），否则沿用现有“未知容量”路径。

### 9.3 发送前校验（`chat_provider_generate.dart:389`）

无需改动。网关档案缺地址或令牌时 `cfg.error` 非空，按现有 `SendRejectReason.configInvalid` 拒绝并显示 §6.1 的文案。

### 9.4 运行环境卡片（`settings_screen.dart:305`）

`_EnvironmentCard` 显示 `localConfig` 的状态文字时，`source == 'gemini_gateway'` 显示“GEMINI网关 · <模型>”。

---

## 十、文件清单

新增：

| 文件 | 内容 |
|---|---|
| `lib/core/llm/gemini_gateway.dart` | 常量、`normalizeGatewayBaseUrl`、连接码解析与地址探测、`probeGeminiGateway`、`GatewayStatus` 解析、`compileGatewayThinking`、`GatewayError` 与 `parseGatewayHttpError` |
| `lib/core/llm/gateway_sse.dart` | `decodeGatewaySse` 与事件类型 |
| `lib/core/llm/gemini_gateway_backend.dart` | `GeminiGatewayBackend`（`buildBody`、`generate`、`listModels`） |
| `lib/presentation/providers/gemini_gateway_provider.dart` | `geminiGatewayStatusProvider` |
| `lib/presentation/screens/settings/gemini_gateway_setup_screen.dart` | §5.2 配置页 |
| `lib/presentation/screens/settings/gemini_gateway_status_sheet.dart` | §5.5 额度面板 |
| `test/gemini_gateway_*_test.dart` | §13 单测 |
| `test/support/fake_gemini_gateway.dart` | 本地假网关（`HttpServer`，脚本化响应） |

修改：

| 文件 | 改动 |
|---|---|
| `lib/core/llm/connection_profile.dart` | `ProfileKind.geminiGateway`、`fromKey` |
| `lib/core/llm/llm_backend.dart` | `LlmChunk` 新字段 |
| `lib/core/llm/llm_backends.dart` | `backendFor` 三分支；共享 Dio 对网关后端可见 |
| `lib/core/llm/local_llm_config.dart` | 网关分支 |
| `lib/presentation/providers/chat_provider_local.dart` | `backendFor`；网关思考编译；收集 `dropped`/`note` 与网关追踪信息 |
| `lib/presentation/providers/chat_provider.dart` | `_GenResult.gatewayTrace` |
| `lib/presentation/providers/chat_state.dart` | `lastGatewayTrace` |
| `lib/presentation/providers/chat_provider_vectors.dart` | §9.1 |
| `lib/presentation/screens/settings/connection_profiles_screen.dart` | §5.1 预置段 |
| `lib/presentation/screens/settings/settings_ai_screen.dart` | §5.4 测试分派、§5.6 |
| `lib/presentation/screens/settings/settings_screen.dart` | §9.4 |
| `lib/presentation/screens/chat/sheets/request_info_sheet.dart` | §5.7 |
| `pubspec.yaml` | `1.14.0+120` |

不新增第三方依赖。

---

## 十一、远程模式（Phase B，非 v1.14.0 必做）

远程模式下手机连接 SillyTavern，生成由酒馆 Node 服务端请求网关（内核文档 §11.4）。App 不直接接触网关，也不持有网关令牌。

本次只做文档引导：远程模式下连接档案页的预置卡片显示为灰色说明卡：“远程模式下请在 SillyTavern 中选择 Custom (OpenAI-compatible)，地址与令牌见电脑上 eatgemini『接入 → SillyTavern』页。”不提供一键写入酒馆设置（会改动服务端配置，且需要处理酒馆版本差异）。

远程消费层 `SillyTavernClient.sendMessageStream()` 的 EOF 判定问题（内核文档 §11.4）与网关无关但影响断流表现，单独排期，可复用本文的 `decodeGatewaySse`。

---

## 十二、后续建议（不在本次范围）

- `OpenAiCompatibleBackend` 同样存在“自然 EOF 当完成”的问题。本次网关后端验证稳定后，可让通用后端也改用 `decodeGatewaySse` 与完成判定；改动会影响所有 OpenAI 兼容源，需单独评审。
- `probeLlmEndpoint` 的 `max_tokens=1` 生成探测对按次计费的端点同样有成本，建议改为用户显式点击“发送测试消息”时才执行。

---

## 十三、测试

### 13.1 单元测试

| # | 用例 | 断言 |
|---|---|---|
| T1 | `buildBody`：extraBody 含 `thinking`、`enable_thinking`、`include_reasoning`、`chat_template_kwargs` | body 中都不存在 |
| T2 | `buildBody`：`min_p: 0`、`top_a: 0`、`repetition_penalty: 1`、`logit_bias: {}` | 都不发送，`dropped` 为空 |
| T3 | `buildBody`：`min_p: 0.05`、`repetition_penalty: 1.1`、`logit_bias: {"123": 5}` | 都不发送，`dropped` 含三项 |
| T4 | `buildBody`：`frequency_penalty: 0`、`seed: 0`、`top_k: 40` | 原样发送 |
| T5 | `buildBody`：同时有 `maxTokens` 与 `max_completion_tokens` | 只有 `max_tokens`，值取 `max_completion_tokens` |
| T6 | `buildBody`：固定 `stream: true` 与 `include_usage` | 是 |
| T7 | `compileGatewayThinking` 全组合 | 符合 §7.3 表；`supported` 为空时不发 |
| T8 | `decodeGatewaySse`：CRLF、单独 `\r`、多行 data、`:` 注释、`data:` 无空格、中文字符被拆在两个字节块之间 | 事件与原文一致 |
| T9 | `decodeGatewaySse`：单事件 > 1 MiB | 抛 `GatewayProtocolException` |
| T10 | 后端完成判定：①有 finish + `[DONE]` ②有 finish 无 `[DONE]` ③无 finish + `[DONE]` ④无 finish 自然 EOF ⑤正文后收到 error 帧 ⑥畸形 JSON | ①② done；③④ `incomplete_stream`；⑤按错误码映射；⑥ `gateway_protocol` |
| T11 | `parseGatewayHttpError` + `describe`：§8.2 每一行，固定时钟 | 文案与恢复时间正确；有 requestId 时追加 |
| T12 | `parseGatewayConnectCode`：正确、缺填充、错前缀、`v=2`、`urls` 空、JSON 损坏 | 正确返回或 null，不抛异常 |
| T13 | `normalizeGatewayBaseUrl` 四种输入 | 都得到 `http://host:port/v1/` |
| T14 | `LocalLlmConfig.resolve`：网关档案无令牌 / 无地址 / 完整 | `error` 文案与 `headers` 正确，不含 UA 与会话头 |
| T15 | `ProfileKind.fromKey('geminiGateway')` 往返；未知值回落 | 正确 |
| T16 | `probeGeminiGateway` 使用假 Dio 适配器 | 只出现 GET 请求；401、连接拒绝、非 eatgemini 响应的文案正确 |
| T17 | 摘要旁路收到 error | 返回空串，不写入 summary |
| T18 | 请求头 | 只有 `Authorization`、`X-Router-Trace`、`Content-Type`；共享 Dio 的 `options.headers` 未被写入 |

### 13.2 集成测试（`test/support/fake_gemini_gateway.dart`）

假网关按脚本返回 `/healthz`、`/v1/models`、`/router/status` 和指定的 SSE 序列或错误。

| # | 场景 | 预期 |
|---|---|---|
| I1 | 粘贴连接码 → 自动测试 → 保存并启用 → 发送消息 | 回复正常显示；本次发送详情显示实际模型、尝试次数、请求 ID |
| I2 | 网关输出两段正文后断开连接 | 消息保留两段正文，显示“回复在中途中断”错误卡片；不触发自愈或自动重试 |
| I3 | 429 `router_quota_unavailable` + `retry_after_seconds: 3600` | 显示“预计 HH:mm 恢复”；没有第二次请求 |
| I4 | 503 `gateway_needs_key` | 显示“电脑上的 eatgemini 还没有填写 Google API Key” |
| I5 | 生成中点停止 | 假网关观察到连接关闭；消息按取消处理 |
| I6 | 预设中有 `min_p: 0.05` | 请求成功；SnackBar 提示一次；本次发送详情的“GEMINI网关”分组列出被忽略参数 |
| I7 | 测试连接 | 假网关的 `/v1/chat/completions` 调用次数为 0 |
| I8 | 清除配置 | 档案与令牌被删除，卡片回到“未配置”；若之前是激活档案，激活切到其他档案或无 |

### 13.3 真机联调（依赖 eatgemini M1）

| # | 场景 |
|---|---|
| E1 | 模拟器 `10.0.2.2`，eatgemini 回环模式，流式聊天 |
| E2 | 真机，eatgemini 局域网模式，连接码接入，流式聊天 |
| E3 | 电脑上 eatgemini 退出后发送 | 显示连不上的排查文案 |
| E4 | 在 eatgemini 重新生成 pockettavern 令牌后发送 | 显示令牌无效文案 |
| E5 | 额度面板与 eatgemini 监控窗口数字一致 |

---

## 十四、发布与回退

- v1.14.0 发布说明要点：新增预置端点 GEMINI网关；需要电脑上运行 eatgemini；Google Key 不进手机；网关中断时会明确提示而不是当作完成。
- 不加功能开关：预置卡片默认可见，未配置时不影响任何现有流程。
- 回退：切换到其他连接档案即可。降级到 v1.13.x 时，`geminiGateway` 档案被当作 OpenAI 兼容档案读取，仍可聊天但失去本文的严格完成判定与错误映射；令牌仍在加密存储中。
- 数据兼容：档案 JSON 结构不变，只新增一个 `kind` 取值；不需要迁移。

---

## 十五、风险

| 风险 | 影响 | 应对 |
|---|---|---|
| 工作区未提交修改与本文改动冲突 | 合并困难 | 开工前先提交或合入现有修改，以提交后的代码重新核对 §2 行号 |
| 网关 `/router/status` 未就绪或未返回 `reasoningEfforts` | 思考设置不生效 | 按 §7.3 不发思考参数并给出提示，不影响正常聊天 |
| 用户预设大量使用 `min_p` 等采样参数 | 行为与其他源不同 | 不发并明确提示，不让请求失败 |
| 手机与电脑不在同一网络 | 无法使用 | 测试连接与错误文案给出排查清单；远程使用需走酒馆中转（§11） |
| 自动总结、空正文自愈额外消耗免费额度 | 额度比预期少 | 界面提示；额度面板可见 |

