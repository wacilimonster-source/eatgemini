# 产品设计：eatgemini 桌面单文件版（GUI 监控 + 本地密钥）

> 日期：2026-11-06
> 状态：开发交付稿，M0 技术验证通过后进入 M1
> 依赖文档：[产品设计-Gemini额度路由网关-2026-11-06.md](./产品设计-Gemini额度路由网关-2026-11-06.md)（下称“内核文档”）
> 配套文档：[改造方案-pockettavern-GEMINI网关预置端点-2026-11-06.md](./改造方案-pockettavern-GEMINI网关预置端点-2026-11-06.md)（下称“客户端文档”）
> 平台：Windows 10 1809+ / Windows 11，x64

---

## 一、与内核文档的关系

内核文档定义选路、配额、错误分类、流式提交边界和 HTTP 契约，本文全部沿用，不重复描述。本文只定义“把内核包装成一个双击即用的 Windows 程序”所需的部分：进程与窗口、监控界面、密钥管理、本地存储、对外暴露面和构建打包。

下表列出本文**覆盖**内核文档的条目。冲突时以本文为准，其余以内核文档为准。

| 内核文档条目 | 内核文档做法 | 桌面版做法 | 原因 |
|---|---|---|---|
| §5 `upstream.apiKeyEnv`、`auth.*.tokenEnv`、`auth.adminTokenEnv` | 密钥和令牌从环境变量读取 | 由界面录入，存本机加密文件（§6）；环境变量只作为可选兜底 | 用户要求手动填写、本地保存 |
| §4 `config/router.json` | 配置放仓库目录 | 默认配置编译进 exe；运行配置在 `%LOCALAPPDATA%\eatgemini\config.json` | 单文件分发，exe 旁边不放任何文件 |
| §10 `/router/state`、`/router/refresh` 用管理令牌 | 网关端口上的管理接口 | 管理功能全部移到只监听回环、随机端口的控制台服务（§9），网关端口不再提供管理接口 | 管理面永远不进局域网 |
| §10 `/v1/models` 不扩充字段 | 只返回标准字段 | 允许追加已核验的 `context_window`、`max_output_tokens`（§10.2） | pockettavern 现有上下文预算逻辑读这两个字段 |
| — | 无 | 新增客户端只读接口 `GET /router/status`、增强 `GET /healthz`（§10） | 手机端显示额度、连接测试不耗额度 |
| §5 `projectRef` 示例写真实项目号 | 写入配置 | 默认值 `default`，由用户在界面里改成自己认得的标签 | 不在分发物里带任何账号信息 |

内核代码（`lib/src/core`、`quota`、`http`）不因桌面版改变接口。桌面版新增的模块只通过内核已有的注入点（`Transport`、`Clock`、`StateStore`、配置快照）接入。

---

## 二、目标与范围

### 2.1 目标用户与场景

一位玩家在自己的 Windows 电脑上运行 eatgemini，SillyTavern（同机或局域网）和手机上的 pockettavern 通过它使用同一个 Google 项目的 Gemini 免费额度。用户不熟悉命令行，也不想装 Dart/Node。

### 2.2 必须满足的用户结果

| # | 用户结果 | 验收口径 |
|---|---|---|
| G1 | 双击 `eatgemini.exe` 就能用 | 不需要安装、不需要运行时、exe 旁边不需要其他文件；3 秒内出现监控窗口；不出现黑色控制台窗口 |
| G2 | 第一次启动能在界面里填 Google API Key | 引导页填写 → 测试 → 保存；测试不消耗生成额度 |
| G3 | 密钥只存在本机，不会被上传 | 加密落盘；只会作为请求头发往 Google 官方端点；日志、界面、导出、错误响应中都不出现明文（§7 定义可验证的保证） |
| G4 | 能实时看到网关在干什么 | 服务状态、各模型额度估算与封锁原因、正在进行和最近的请求、下次重置时间 |
| G5 | 能方便地把手机/酒馆接上 | 界面直接给出地址、访问令牌、模型名，可一键复制；给 pockettavern 生成“连接码” |
| G6 | 关掉窗口不影响使用，想退出时能退出 | 关窗口后网关继续在后台运行，托盘图标可重新打开或退出 |

### 2.3 不做

- 安装包、自动更新、开机自启（自启放到 M2，默认关闭）。
- 多 Google 账号/多项目轮换（内核文档已排除）。
- 云同步、遥测、崩溃上报、在线公告，以及任何发往 Google 生成接口之外的网络请求。
- 代码签名（M1 不签名，§12.4 说明 SmartScreen 提示）。
- macOS / Linux 版本。

---

## 三、技术选型

### 3.1 结论

**Dart AOT 单文件 exe + 内嵌的本地网页控制台 + Edge 应用窗口 + Win32 托盘。**

| 方案 | 单文件 | 复用内核 | 界面开发量 | 结论 |
|---|---|---|---|---|
| Dart `compile exe` + 本地网页控制台，用 Edge `--app` 打开 | 是，界面资源编译进 exe | 直接复用 | HTML/CSS/原生 JS，无构建链 | **采用** |
| Flutter Windows 桌面 | 否，产物是 exe + 多个 dll + data 目录，打成单文件要第三方封装 | 复用 | 中 | 不采用 |
| Go + Wails/WebView2 | 是 | 需要重写内核或跨语言调用 | 中 | 不采用：内核已定 Dart |
| Dart + WebView2 FFI 内嵌窗口 | 是 | 复用 | WebView2 COM 接口的 FFI 绑定量大 | M2 再评估 |

Edge（Chromium 版）是 Windows 10 1809+ 和 Windows 11 的系统组件，可以视为已存在；找不到时退回默认浏览器（§4.4）。

### 3.2 依赖

| 依赖 | 用途 | 约束 |
|---|---|---|
| Dart SDK 3.x（固定小版本，写入 `tool/SDK_VERSION`） | 编译 | 构建机固定版本，保证可复现 |
| `timezone` | 太平洋时间重置（内核文档 §9.3） | 只加载 `latest_10y` 数据，控制体积 |
| `win32`、`ffi` | DPAPI、托盘、互斥体、ShellExecute、注册表、MessageBox | 只在 `lib/src/desktop`、`lib/src/secrets` 里使用 |
| `dart:io` `HttpServer` | 网关服务和控制台服务 | 不引入 Web 框架 |
| `test`（开发依赖） | 测试 | — |

界面不使用任何前端框架和 CDN 资源；全部静态文件由构建脚本转成 Dart 字节常量编进 exe（§12.1）。

---

## 四、进程、窗口与生命周期

### 4.1 进程模型

```text
eatgemini.exe（单进程，GUI 子系统，无控制台）
├─ 主 isolate
│  ├─ AppController     启动编排、状态机（§4.3）、退出
│  ├─ GatewayServer     内核 HTTP 服务（默认 127.0.0.1:8787，可切 LAN）
│  ├─ ConsoleServer     控制台网页 + 管理 API（只绑 127.0.0.1，随机端口）
│  ├─ RouterKernel      内核文档 §6–§9
│  ├─ SecretVault       DPAPI 加密的密钥库（§6）
│  ├─ EgressGuard       出站白名单（§7.2）
│  └─ EventBus / RequestLog / Logger
├─ 托盘 isolate        Win32 消息循环 + Shell_NotifyIconW，与主 isolate 用 SendPort 通信
└─（外部进程）msedge.exe --app=…   监控窗口，独立用户数据目录
```

关闭监控窗口只结束 Edge 进程，网关进程不受影响。

### 4.2 启动流程

1. **解析参数**：`--minimized`（不弹窗口）、`--console`（附加调试控制台，§4.6）、`--data-dir <path>`（开发用）、`--version`（配合 `--version-out <file>` 把版本写入文件后退出，供构建校验；GUI 子系统下没有 stdout）。
2. **单实例**：`CreateMutexW("Local\\eatgemini-<用户 SID 哈希>")`。
   - 已存在：读取 `instance.json` 中的控制台端口与 `ipcNonce`，`POST http://127.0.0.1:<port>/ipc/show`（头 `X-Eatgemini-Ipc: <nonce>`）让已有实例打开窗口，然后退出。2 秒无响应时弹 MessageBox“eatgemini 已在运行但没有响应，请在任务管理器结束后重试”，然后退出。
   - 不存在：继续。另外对数据目录加文件锁（内核文档 §3），两层都通过才继续。
3. **数据目录**：创建 `%LOCALAPPDATA%\eatgemini\` 及子目录（§5）。`config.json` 不存在时写入编进 exe 的默认配置。
4. **加载配置**：按内核规则整体校验。失败进入 `config_error`，网关不启动，控制台照常启动，界面提供“查看错误”“恢复默认配置（原文件改名备份）”。
5. **解锁密钥库**：DPAPI 解密 `secrets.dat`（§6.3）。没有上游 Key 时进入 `needs_key`。
6. **启动 ConsoleServer**：`127.0.0.1:0` 取随机端口；生成本次运行的 `ipcNonce` 与一次性启动票据（§9.1）；写 `instance.json`。
7. **启动 GatewayServer**：按配置监听。端口被占用进入 `port_conflict`，界面提示并允许改端口后热重绑，不需要重启程序。`needs_key` 状态下网关照常监听，对生成请求返回 503 `gateway_needs_key`，让客户端看到明确原因而不是“连不上”。
8. **启动托盘 isolate**。
9. **打开窗口**（§4.4），`--minimized` 或设置“启动时不打开窗口”时跳过。
10. **后台检查**：已有 Key 时做一次上游连通性检查（内核文档 §13.2：`GET models`，5 秒超时，不生成）。

任一步出现未捕获异常：写日志，弹 MessageBox 显示简短原因和日志路径，退出码非 0。

### 4.3 应用状态机

| 状态 | 含义 | 网关对生成请求 | 托盘图标 |
|---|---|---|---|
| `starting` | 启动中 | 不监听 | 灰 |
| `needs_key` | 没有可用的上游 Key | 503 `gateway_needs_key` | 黄 |
| `config_error` | 配置无效 | 不监听 | 红 |
| `port_conflict` | 网关端口被占用 | 不监听 | 红 |
| `ready` | 正常 | 按内核选路 | 绿 |
| `degraded` | 上游连通性检查失败，或最近 5 分钟持续出现端点级故障 | 照常尝试（内核分类决定结果） | 黄 |
| `persist_error` | 状态写盘失败（内核文档 §9.3） | 503 `gateway_persist_error`，停止新准入 | 红 |
| `stopping` | 退出中 | 拒绝新请求，等待在途 | 灰 |

额度用尽不是故障状态：应用仍是 `ready`，界面另用“今日额度受限”徽标表示（来自内核桶状态）。

### 4.4 监控窗口

按顺序查找浏览器：

1. `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe`（再查 HKCU 同路径）。
2. `%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe`、`%ProgramFiles%\Microsoft\Edge\Application\msedge.exe`。
3. 同样方式查 `chrome.exe`。
4. 都没有：`ShellExecuteW` 用默认浏览器打开普通标签页，界面顶部提示“未找到 Edge，已用默认浏览器打开”。

启动命令（参数数组传给 `Process.start`，不经 shell 拼接）：

```text
msedge.exe
  --app=http://127.0.0.1:<consolePort>/ui/launch?t=<一次性票据>
  --user-data-dir=%LOCALAPPDATA%\eatgemini\webview
  --no-first-run --no-default-browser-check
  --disable-sync --disable-features=Translate,msEdgeShopping,AutofillServerCommunication
  --window-size=1180,780
```

- 独立的 `user-data-dir` 保证：不登录微软账号、不和用户日常浏览器共享密码管理和同步；关闭窗口只关这个独立实例。
- 托盘“打开监控窗口”或再次双击 exe：已有窗口时仍执行上面的命令。Edge 对同一 `user-data-dir` 会把新窗口交给已有进程，可能多开一个窗口；M1 接受，界面会话互不影响。
- 窗口关闭检测：控制台的 SSE 连接全部断开超过 5 秒，视为窗口已关闭。首次发生时托盘弹气泡“eatgemini 仍在后台运行，可从托盘图标重新打开”，之后不再提示（记入配置 `desktop.closeHintShown`）。

### 4.5 退出

入口：托盘“退出”、界面“退出 eatgemini”（二次确认，若有在途请求显示数量）。

1. 状态切到 `stopping`，网关停止接受新连接，生成请求返回 503 `gateway_stopping`。
2. 等待在途请求最多 10 秒；超时后取消上游请求，已提交的流按内核文档 §8 发 SSE error 并关闭。
3. 内核状态落盘，删除 `instance.json`，释放文件锁和互斥体，移除托盘图标。
4. 控制台页面收到 SSE `app.stopping` 后显示“eatgemini 已退出，可以关闭此窗口”。

收到 `WM_QUERYENDSESSION`（Windows 注销/关机）时走同样流程，等待上限缩短为 3 秒。

### 4.6 无控制台与日志输出

发布版 exe 的 PE 子系统改为 GUI（§12.2），不再有控制台窗口。这样运行时**不能依赖 stdout/stderr**：

- 所有输出走 `Logger`（§11.1），写日志文件。
- `main()` 用 `runZonedGuarded` 包住全部逻辑，并通过 `ZoneSpecification.print` 把 `print` 重定向到 `Logger`，防止第三方代码向无效句柄写入。
- 所有 `stdout`/`stderr` 写入调用只允许出现在 `--console` 分支里。
- `--console`：调用 `AllocConsole()` 分配控制台，日志同时输出到控制台，便于排障。

M0 必须验证：GUI 子系统下 Dart 运行时启动、`HttpServer`、`Process.start`、isolate 和异常路径都正常，且残留的 stdout 写入不会让进程崩溃或阻塞。若验证失败，备选方案是保留控制台子系统，在 `main()` 第一行调用 `FreeConsole()`；代价是启动时控制台会闪一下，需在交付说明中注明。

---

## 五、本地数据目录

固定使用 `%LOCALAPPDATA%\eatgemini\`。不用 `%APPDATA%`（Roaming）：域环境下 Roaming 目录会同步到服务器，与“不上传”冲突。

```text
%LOCALAPPDATA%\eatgemini\
├─ config.json            用户可见配置（不含任何密钥），§8
├─ config.json.bak        上一次有效配置
├─ secrets.dat            DPAPI 加密的密钥库，§6
├─ secrets.dat.bak        上一次有效密钥库（同样加密）
├─ state\                 内核 StateStore（内核文档 §9），含 .lock
├─ logs\
│  ├─ eatgemini-YYYYMMDD.log      文本日志，已脱敏
│  └─ requests-YYYYMMDD.jsonl     请求元数据，已脱敏，§11.2
├─ instance.json          运行中实例信息：{pid, consolePort, ipcNonce, startedAt}
├─ webview\               Edge 独立用户数据目录
└─ exports\               用户主动导出的诊断包
```

- 目录继承 `%LOCALAPPDATA%` 的默认 ACL（仅当前用户、SYSTEM、Administrators）。M1 不自行设置 ACL，启动时只检查目录可写。
- `instance.json` 中的 `ipcNonce` 只能让同一用户的进程打开窗口，不能读取任何数据（§9.3）。
- 便携模式（exe 同目录下存在 `eatgemini.portable` 空文件时，数据目录改为 exe 同目录的 `eatgemini-data\`）放到 M2。即使便携，`secrets.dat` 也只能被加密时的同一 Windows 用户解开，换电脑需要重新填 Key。

---

## 六、密钥管理

### 6.1 密钥种类

| 密钥 | 来源 | 用途 | 界面显示 |
|---|---|---|---|
| 上游 Google API Key | 用户手动填写 | 网关调用 Google 时注入请求头 | 永远只显示 `AIza…wxyz`（前 4 后 4） |
| 客户端访问令牌 `sillytavern` | 程序生成 | SillyTavern 调网关时的 Bearer | 默认遮挡，可“显示”“复制”“重新生成” |
| 客户端访问令牌 `pockettavern` | 程序生成 | 手机调网关时的 Bearer | 同上；用于生成连接码 |
| 控制台会话 | 每次运行随机生成 | 控制台网页鉴权（§9.1） | 不显示 |

内核文档中的 `EATGEMINI_ADMIN_TOKEN` 在桌面版中取消，管理权限由控制台会话承担。

客户端令牌格式：前缀 + 32 字节 `Random.secure()` 的 base64url（无填充）。

- `sillytavern`：`egw_st_<43 字符>`
- `pockettavern`：`egw_pt_<43 字符>`

前缀用于日志脱敏识别和用户辨认，不参与鉴权逻辑；鉴权按内核规则用常量时间比较整串。

### 6.2 加密存储格式

`secrets.dat` 为 UTF-8 JSON 外壳：

```json
{
  "format": "eatgemini-secrets",
  "version": 1,
  "protection": "dpapi-user",
  "salt": "<16 字节随机数 base64>",
  "blob": "<CryptProtectData 输出 base64>"
}
```

- 加密：`CryptProtectData(plaintext, szDataDescr="eatgemini", pOptionalEntropy=SHA256("eatgemini/secrets/v1" + salt), dwFlags=CRYPTPROTECT_UI_FORBIDDEN)`。不使用 `CRYPTPROTECT_LOCAL_MACHINE`，只有当前 Windows 用户能解开。
- 解密：`CryptUnprotectData`，参数对应；输出缓冲区用 `LocalFree` 释放。
- 明文结构：

```json
{
  "upstream": {
    "apiKey": "AIza...",
    "addedAt": "2026-11-06T08:00:00Z",
    "lastVerifiedAt": "2026-11-06T08:00:05Z",
    "lastVerifyResult": "ok"
  },
  "clients": {
    "sillytavern": {"token": "egw_st_...", "createdAt": "2026-11-06T08:00:00Z"},
    "pockettavern": {"token": "egw_pt_...", "createdAt": "2026-11-06T08:00:00Z"}
  }
}
```

- 写入：先写 `secrets.dat.tmp` 并 flush，再把旧文件改名为 `.bak`，最后把 tmp 改名为正式文件（与内核文档 §9.3 相同，Windows 替换行为在 M0 实测）。
- 首次启动没有 `secrets.dat` 时，生成两个客户端令牌并立即写入，上游 Key 为空。

### 6.3 解密失败

可能原因：文件从别的电脑或别的 Windows 用户复制过来、Windows 重装、文件损坏。

1. 尝试 `secrets.dat.bak`。
2. 都失败：把两个文件改名为 `*.unreadable-<时间戳>`（不删除），重新生成客户端令牌，进入 `needs_key`。
3. 界面顶部红条：“本机无法解开之前保存的密钥（可能是换了电脑或 Windows 用户）。请重新填写 Google API Key；手机和酒馆需要重新填写新的访问令牌。”

### 6.4 内存中的密钥

- `SecretVault` 解密后在主 isolate 内存中持有一个 `Secrets` 对象。`Secrets`、`ApiKey`、`ClientToken` 的 `toString()` 一律返回遮挡值，防止被意外写进日志或异常信息。
- 托盘 isolate 不接收任何密钥。
- Dart 字符串不能可靠清零，M1 不承诺内存擦除，只保证密钥不出现在进程之外（文件明文、日志、网络）。

### 6.5 环境变量兜底

`secrets.dat` 中没有上游 Key、且环境变量 `GEMINI_API_KEY` 有值时，使用环境变量。界面显示“来源：环境变量（只读）”，不能在界面里修改或删除；用户在界面保存新 Key 后以界面保存的为准。客户端令牌不读环境变量。

### 6.6 填写与测试流程

“密钥”页和首次启动引导页使用同一个表单组件。

**输入框**

- `<input type="text" autocomplete="off" autocapitalize="off" spellcheck="false">`，CSS `-webkit-text-security: disc` 显示为圆点，右侧“显示”按钮切换。不用 `type="password"`，避免浏览器弹“保存密码”。
- `name` 属性每次渲染随机生成，降低自动填充命中。
- 本地检查：去掉首尾空白后长度 30–60、只含 `[A-Za-z0-9_-]`，不满足直接提示格式错误，不发送。不以 `AIza` 开头时提示“看起来不像 Google AI Studio 的 Key，确定继续吗”，可继续。

**“测试并保存”**

1. 控制台 API 收到 Key，交给 `UpstreamVerifier`。
2. `GET {baseUrl}models`（Authorization: Bearer <Key>），10 秒超时，走当前代理配置。**不发任何生成请求。**
3. 按结果处理：

| 结果 | 界面提示 | 是否保存 |
|---|---|---|
| 200 且返回模型列表 | “验证通过”，并列出配置中启用的模型哪些出现在列表里 | 保存 |
| 401，或 400 且明确是 Key 无效 | “Key 无效，请检查是否复制完整” | 不保存 |
| 403 | 显示脱敏后的上游原因（地区、项目未启用 API 等），说明“Key 本身可能没问题，但当前项目或地区无权访问” | 询问“仍要保存吗” |
| DNS、代理连接、TLS、超时 | 分别说明，并提示去“设置 → 网络代理”检查 | 询问“未能验证，仍要保存吗” |

4. 保存成功：更新 `lastVerifiedAt/lastVerifyResult`，应用状态从 `needs_key` 进入 `ready` 或 `degraded`，向 EventBus 发 `secrets.changed`。

模型列表接口可访问不代表模型能生成或仍有免费额度（内核文档 §13.2）；界面文案只说“Key 可用”，不说“额度正常”。

### 6.7 更换与删除

- **删除 Key**：二次确认 → 清除 → 进入 `needs_key`。在途请求继续用旧 Key 完成，新请求 503。
- **更换 Key**：弹窗询问“新 Key 属于同一个 Google 项目吗？”
  - 是：保留额度估算状态（内核文档 §9.3：换 Key 不清额度）。
  - 否：要求填写新的项目标签（`projectRef`），内核按新标签建立新的状态作用域，旧状态保留在磁盘不删除。
- **重新生成客户端令牌**：二次确认，提示“旧令牌立即失效，需要在酒馆/手机上重新填写”。生成后旧令牌的请求立即返回 401。

---

## 七、“密钥不上传”的具体保证

“不上传”指：**上游 Key 只会作为请求头发送给配置的 Google 官方端点；任何密钥都不会发往其他地方，也不会以明文形式离开本机内存。** 下表每一条都对应可自动化的测试。

### 7.1 保证清单

| # | 保证 | 实现 | 测试 |
|---|---|---|---|
| N1 | 程序只连接上游端点和用户配置的代理 | §7.2 EgressGuard | 对非白名单主机发请求必须在建立连接前失败 |
| N2 | 不存在遥测、崩溃上报、更新检查、在线字体/脚本 | 代码中不包含此类功能；界面资源全部本地 | 构建后扫描界面资源中不含 `http://`、`https://` 外链；CSP 拦截验证 |
| N3 | Key 只放在请求头，不放 URL | Transport 用 `Authorization: Bearer`，URL 构造函数禁止携带 `key=` 查询参数 | 单测断言所有上游请求 URL 不含 Key |
| N4 | 网关下游响应不含 Key | 错误 envelope、trace 头、SSE error、`/router/status` 全部经过 Redactor | 假上游在错误信息里回显 Key，断言下游响应不含 |
| N5 | 日志、请求记录、诊断包不含密钥 | Redactor（§7.3）作用于 Logger 的所有输出 | 同上，断言日志文件不含 |
| N6 | 落盘的密钥只有 `secrets.dat` 中的 DPAPI 密文 | `config.json`、状态文件的类型里没有密钥字段 | 扫描数据目录所有文件，不含测试 Key 和令牌明文 |
| N7 | 控制台页面不能把数据发往外部 | CSP（§9.2） | 页面注入外链请求，断言被拦截 |
| N8 | 分发的 exe 不含任何开发者 Key | 构建脚本检查 | 发布前扫描 exe 字符串，不含 `AIza[0-9A-Za-z_-]{30,}` |

### 7.2 EgressGuard

所有出站连接只能通过 `GuardedTransport`，它包住内核的 `Transport`：

- 白名单 = 配置中 `upstream.baseUrl` 的 `scheme + host + port`，加上用户配置的代理 `host:port`（代理只作为 CONNECT 隧道的下一跳）。
- 默认上游 `https://generativelanguage.googleapis.com/v1beta/openai/`。用户改成其他 host 时，界面红字警告“Key 将发送给 <host>，请确认这是你信任的端点”，并要求勾选确认后才能保存。
- 只允许 `https`；`http` 上游直接拒绝保存（反向代理调试需求不在 M1 范围）。
- 禁止跟随跨主机重定向（内核文档 §13.2）；同主机重定向最多 3 次。
- 被拒绝的出站尝试记 `error` 日志（只记 host，不记路径和头）。

### 7.3 Redactor

在 Logger、RequestLog、诊断导出、所有下游错误 message 生成处统一调用：

1. **精确替换**：当前 vault 中的上游 Key、两个客户端令牌，以及本次运行出现过的旧值，按字面替换为 `[REDACTED:upstream_key]`、`[REDACTED:client_token]`。
2. **模式替换**：`AIza[0-9A-Za-z_-]{30,}` → `[REDACTED:google_key]`；`egw_(st|pt)_[0-9A-Za-z_-]{20,}` → `[REDACTED:client_token]`；`Bearer\s+\S+` → `Bearer [REDACTED]`。
3. **代理凭据**：`//user:pass@` → `//[REDACTED]@`。
4. 截断：单条消息最长 2000 字符。

Redactor 只处理元数据和错误文本；prompt 与回复正文按内核文档 §13.3 本来就不记录。

---

## 八、运行配置

### 8.1 与内核配置的差异

桌面版 `config.json` 为 `version: 3`。相对内核文档 §5 的 v2：

- 删除 `upstream.apiKeyEnv`、`auth.adminTokenEnv`、`auth.clients.*.tokenEnv`（改由 vault 提供）。`auth.clients` 只保留 `compatibility` 与 `allowedProfiles`。
- `listen` 增加 `mode`：`loopback`（绑 `127.0.0.1`）或 `lan`（绑 `0.0.0.0`，或 `bindAddress` 指定的网卡地址）。
- `upstream.proxy` 改为对象（§8.3）。
- 新增 `desktop`、`console` 两段。
- `projectRef` 默认 `"default"`。

内核加载配置时接收的是一个已合并的快照：`config.json` + vault 中的 Key/令牌。内核代码不读环境变量，也不知道 vault 的存在。

v2 → v3 迁移：首次启动若发现 v2 文件（如开发者从仓库复制），按上面规则转换，原文件备份为 `config.v2.bak.json`；若 v2 指定的环境变量当前有值，界面询问“是否把环境变量中的 Key/令牌导入本机密钥库”，同意才导入。

### 8.2 默认配置（节选）

`profiles`、`models`、`quotaGroups`、`policy`、`logging`、`compatibility` 与内核文档 §5 相同，并按内核 §2 补全六个模型；以下只列桌面版改动的部分：

```json
{
  "version": 3,
  "projectRef": "default",
  "quotaSnapshot": {"observedAt": "2026-11-06", "source": "original-design", "verified": false},
  "upstream": {
    "baseUrl": "https://generativelanguage.googleapis.com/v1beta/openai/",
    "proxy": {"mode": "none", "host": null, "port": null},
    "connectTimeoutMs": 10000,
    "firstEventTimeoutMs": 45000,
    "streamIdleTimeoutMs": 60000
  },
  "listen": {"mode": "loopback", "bindAddress": null, "port": 8787},
  "auth": {
    "clients": {
      "sillytavern": {"compatibility": "tavern_text", "allowedProfiles": ["chat", "fast", "quality"]},
      "pockettavern": {"compatibility": "tavern_text", "allowedProfiles": ["chat", "fast", "quality"]}
    }
  },
  "desktop": {
    "openWindowOnStart": true,
    "browser": "auto",
    "closeHintShown": false,
    "autostart": false
  },
  "console": {
    "requestLogMemory": 500,
    "eventThrottleMs": 250
  }
}
```

### 8.3 代理

| `proxy.mode` | 行为 |
|---|---|
| `none` | 直连 |
| `environment` | `HttpClient.findProxyFromEnvironment`（内核文档 §13.1 的规则） |
| `manual` | 使用 `host`、`port`，HTTP CONNECT 代理；不支持 SOCKS |
| `system`（M2） | 读取 `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings` 的 `ProxyEnable/ProxyServer`；不支持 PAC |

国内常见的本机代理（如原稿记录的 `127.0.0.1:7897`）用 `manual` 填写。设置页提供“测试上游连通”按钮，结果按 DNS / 代理连接 / TLS / HTTP 状态分别展示，测试仍是 `GET models`。

### 8.4 修改配置

- 所有界面修改都经 `PUT /api/config`，携带读取时的 `revision`；服务端发现 revision 不一致返回 409，界面提示“配置已在其他窗口修改，请刷新”。
- 服务端先按内核规则整体校验，再原子写入并替换内存快照；在途请求沿用旧快照（内核文档 §5）。
- 修改 `listen` 触发网关热重绑：先在新地址监听成功，再关闭旧监听；新地址失败则保持旧监听并返回错误。在途请求不受影响。
- 用户手动编辑 `config.json` 后需在界面点“重新加载配置”，M1 不做文件监视。

---

## 九、控制台服务与管理 API

控制台服务只绑定 `127.0.0.1`，端口每次启动随机。它提供监控网页和管理 API。网关端口（8787）上不存在任何管理接口。

### 9.1 会话

1. 启动时生成一次性启动票据（32 字节随机，有效期 60 秒，只能用一次）。
2. 窗口打开 `/ui/launch?t=<票据>`：校验通过后设置 Cookie `egc_session=<随机 32 字节>; HttpOnly; SameSite=Strict; Path=/`，302 到 `/ui/`。票据立即作废。
3. 之后所有 `/api/*` 和 `/ui/*` 请求都要求有效会话；会话只存在内存，程序重启全部失效。
4. 票据过期或缺失时页面显示“请从托盘图标或重新双击 eatgemini.exe 打开监控窗口”，不提供任何其他登录方式。
5. 每次“打开窗口”都生成新票据。

### 9.2 请求校验

对控制台服务的每个请求：

- `Host` 必须是 `127.0.0.1:<consolePort>` 或 `localhost:<consolePort>`，否则 421（防 DNS rebinding）。
- 非 GET 请求要求 `Origin` 等于 `http://127.0.0.1:<consolePort>` 或 `http://localhost:<consolePort>`，并带头 `X-Egc-Csrf: <会话对应的 CSRF 值>`（登录时随页面下发），否则 403。
- 所有响应带：

```text
Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'
X-Content-Type-Options: nosniff
Referrer-Policy: no-referrer
Cache-Control: no-store
```

- 不开放 CORS。

### 9.3 IPC

`POST /ipc/show`：只校验 `Host` 和 `X-Eatgemini-Ipc: <instance.json 中的 nonce>`，作用只有一个：让已有实例执行 §4.4 打开窗口。返回 204。不需要会话，也不返回任何数据。

### 9.4 管理 API

所有响应为 JSON；错误统一 `{"error": {"code": "...", "message": "..."}}`。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/snapshot` | 概览全量数据，页面首次加载用（结构见 §9.6） |
| GET | `/api/events` | SSE 推送，§9.5 |
| GET | `/api/models` | 模型与桶状态（内核 `/router/state` 的内容，加界面需要的展示字段） |
| POST | `/api/models/{id}/enabled` | `{enabled: bool}`，等价于修改配置 |
| POST | `/api/buckets/{bucketId}/clear-local-estimate` | 清除本地估算；上游确认的封锁不清（内核文档 §10），写审计日志 |
| POST | `/api/router/refresh` | 内核 `/router/refresh`：只读上游，返回差异报告，不自动修改配置 |
| GET | `/api/requests?client=&outcome=&model=&before=&limit=` | 请求记录分页，§11.2 |
| GET | `/api/requests/{requestId}` | 单条请求的 attempt 时间线 |
| GET | `/api/connect` | 连接信息：各客户端的地址、遮挡后的令牌、模型名、局域网 IP 列表 |
| POST | `/api/connect/{client}/reveal` | 返回该客户端令牌明文（只回给控制台页面，不写日志） |
| POST | `/api/connect/{client}/rotate` | 重新生成令牌 |
| POST | `/api/connect/pockettavern/code` | 生成连接码（§10.6），返回明文连接码 |
| GET | `/api/secrets/upstream` | `{configured, source: "vault"|"env"|null, masked, addedAt, lastVerifiedAt, lastVerifyResult}` |
| POST | `/api/secrets/upstream/verify` | `{apiKey}`，只测试不保存，返回 §6.6 的分类结果 |
| PUT | `/api/secrets/upstream` | `{apiKey, sameProject: bool, projectRef?}`，测试并保存 |
| DELETE | `/api/secrets/upstream` | 删除 Key |
| GET | `/api/config` | `{revision, config}` |
| PUT | `/api/config` | `{revision, config}`，§8.4 |
| POST | `/api/config/reload` | 重新读取 `config.json` |
| POST | `/api/config/reset` | 恢复默认配置（原文件备份） |
| POST | `/api/upstream/check` | 用当前 Key 和代理做一次连通性检查 |
| GET | `/api/diagnostics` | 版本、路径、Edge 路径、代理模式（脱敏）、最近一次启动检查 |
| POST | `/api/diagnostics/export` | 生成诊断包，§11.3 |
| POST | `/api/app/open-data-dir` | 用资源管理器打开数据目录 |
| POST | `/api/app/exit` | 退出，§4.5 |

管理 API 不提供“读取上游 Key 明文”的接口。用户忘了 Key 只能去 AI Studio 重新复制。

### 9.5 事件流

`GET /api/events`，`text/event-stream`，每 15 秒发 `: ping`。事件格式为 `event: <类型>\ndata: <单行 JSON>\n\n`。

| 事件 | 触发 | data 主要字段 |
|---|---|---|
| `app.state` | 应用状态变化 | `state, reason, since` |
| `request.started` | 生成请求准入 | `requestId, client, requestedModel, profile, stream, startedAt` |
| `request.attempt` | 每次上游尝试开始/结束 | `requestId, attemptId, model, phase(sending|waiting_first_event|streaming|done|failed|skipped), status, classification, latencyMs` |
| `request.finished` | 请求结束 | `requestId, outcome, httpStatus, servedModel, attempts, totalMs, firstEventMs, usage, errorCode` |
| `bucket.changed` | 桶计数或封锁变化 | `bucketId, localAttempts, limit, blockedUntil, reason, confidence` |
| `model.changed` | 模型启用/封锁变化 | `modelId, enabled, blockedUntil, reason` |
| `upstream.check` | 连通性检查结果 | `ok, stage, latencyMs, message` |
| `config.changed` | 配置替换 | `revision` |
| `secrets.changed` | Key 或令牌变化 | `upstreamConfigured, rotatedClient` |
| `log` | `warn` 及以上日志 | `level, message, at` |
| `app.stopping` | 退出中 | — |

- `request.attempt` 与 `bucket.changed` 按 `console.eventThrottleMs` 合并，同一对象在窗口内只发最后一次。
- 页面断线后自动重连，重连成功先拉 `/api/snapshot` 再继续消费事件。

### 9.6 `/api/snapshot` 结构

```json
{
  "app": {"state": "ready", "reason": null, "version": "1.0.0", "startedAt": "2026-11-06T08:00:00Z"},
  "gateway": {"listenMode": "loopback", "addresses": ["http://127.0.0.1:8787/v1"], "port": 8787},
  "upstream": {"configured": true, "lastCheck": {"ok": true, "at": "2026-11-06T08:00:05Z", "latencyMs": 420}},
  "quotaDay": {"day": "2026-11-06", "nextResetAt": "2026-11-07T08:00:00Z", "timezone": "America/Los_Angeles"},
  "today": {"requests": 42, "succeeded": 39, "failed": 3, "fellBack": 7, "upstreamAttempts": 51, "uncertainAttempts": 1},
  "profiles": [
    {"id": "chat", "state": "available", "nextModel": "gemini-3.8-flash", "availableModels": 5, "totalModels": 6, "retryAt": null}
  ],
  "inFlight": [
    {"requestId": "req_abc", "client": "pockettavern", "profile": "chat", "model": "gemini-3.8-flash", "phase": "streaming", "elapsedMs": 3200}
  ],
  "recentRequests": [],
  "models": []
}
```

`profiles[].state` 取值：`available`（有候选可试）、`limited`（所有候选当前受限，`retryAt` 为最早恢复时间或 null）、`unavailable`（无启用候选或无 Key）。

---

## 十、网关对外接口（客户端可见部分）

网关端口上的接口：内核文档 §10 的 `/v1/chat/completions`、`/v1/models`、`/readyz`，加上本节的 `/healthz`（增强）和 `/router/status`（新增）。内核的 `/router/state`、`/router/refresh` 在桌面版不挂到网关端口。

所有网关响应带 `X-Eatgemini-Version: <版本>`。

### 10.1 `GET /healthz`

不鉴权，用于客户端判断“这个地址上是不是 eatgemini、进程活着没有”。

```json
{"status": "ok", "app": "eatgemini", "version": "1.0.0", "api": 1}
```

- `api` 是客户端契约版本号，本文定义的接口为 `1`；破坏性变化时加一，客户端据此提示升级。
- 不返回应用状态、项目、Key 是否配置等信息；这些需要令牌（§10.3）。

### 10.2 `GET /v1/models` 扩展字段

在内核文档 §10 的标准结构上，每个条目可追加两个可选字段：

```json
{
  "object": "list",
  "data": [
    {"id": "router:chat", "object": "model", "created": 0, "owned_by": "eatgemini",
     "context_window": 1048576, "max_output_tokens": 65536}
  ]
}
```

- 具体模型：取配置中已核验的 `inputTokenLimit` / `outputTokenLimit`；为 `null` 时**不输出该字段**。
- 路由别名（`auto`、`router:*`）：取该 profile 所有已启用候选的最小值；任一候选未知则不输出。
- pockettavern 的上下文预算按 `context_window`、`max_output_tokens` 读取（客户端文档 §9.2）。

### 10.3 `GET /router/status`

客户端令牌鉴权（任一客户端令牌），只返回该客户端 `allowedProfiles` 范围内的信息。用于手机显示“额度状态”和连接测试。不触发任何上游请求。

```json
{
  "api": 1,
  "app": {"state": "ready", "reason": null},
  "quotaDay": {"day": "2026-11-06", "nextResetAt": "2026-11-07T08:00:00Z"},
  "profiles": [
    {
      "id": "chat",
      "model": "router:chat",
      "state": "available",
      "nextModel": "gemini-3.8-flash",
      "availableModels": 5,
      "totalModels": 6,
      "retryAt": null,
      "reasoningEfforts": ["low", "high"],
      "contextWindow": 1048576,
      "maxOutputTokens": 65536
    }
  ],
  "models": [
    {
      "id": "gemini-3.8-flash",
      "state": "available",
      "blockedUntil": null,
      "reason": null,
      "rpd": {"used": 17, "limit": 20, "estimated": true}
    }
  ]
}
```

- `app.state` 取 §4.3 的值；`reason` 为面向用户的简短中文。
- `reasoningEfforts`：该 profile 所有启用候选都已核验支持的 `reasoning_effort` 取值的交集；没有核验数据时为空数组，客户端此时不发送思考参数。
- `models[].rpd.used` 是本地估算（内核文档 §9.1 的 `localAttempts`），`estimated` 恒为 `true`；`limit` 为 `null` 表示未知。
- 不返回 `projectRef`、Key 来源、代理、日志、其他客户端的请求记录。
- 限流：同一令牌每 2 秒最多 1 次，结果缓存 1 秒；超出返回 429。

### 10.4 桌面版新增的错误码

沿用内核文档 §10 的 envelope：

| HTTP | `error.code` | 场景 | `message` |
|---|---|---|---|
| 503 | `gateway_needs_key` | 还没填 Google API Key | “eatgemini 还没有配置 Google API Key，请在电脑上的 eatgemini 窗口中填写” |
| 503 | `gateway_persist_error` | 状态写盘失败 | “eatgemini 无法保存额度状态，已暂停接收请求，请查看电脑上的提示” |
| 503 | `gateway_stopping` | 正在退出 | “eatgemini 正在退出” |
| 401 | `invalid_client_token` | 令牌错误或已被重新生成 | “访问令牌无效，请在 eatgemini 窗口的「接入」页复制新令牌” |
| 429 | `auth_rate_limited` | 同一 IP 鉴权连续失败 | “鉴权失败次数过多，请稍后再试” |

内核已定义的 `router_quota_unavailable` 等错误码不变。客户端文档 §8 的错误映射以内核文档与本表为准。

### 10.5 局域网模式

- `listen.mode = "lan"` 时网关绑定 `0.0.0.0:<port>`（或 `bindAddress`）。控制台服务始终只绑 `127.0.0.1`。
- 切换到 LAN 时界面提示：“手机将通过局域网访问本机。Windows 可能弹出防火墙提示，请只勾选『专用网络』。不要在公共 Wi-Fi 下开启。”程序不自动修改防火墙规则（需要管理员权限，且用户应看到并确认）。
- 地址列表：枚举 `NetworkInterface.list(type: IPv4)`，排除回环、`169.254.*`；界面同时列出网卡名，便于用户分辨 Wi-Fi 与虚拟网卡（如 Hyper-V、WSL、VPN）。
- 鉴权失败限流：同一来源 IP 1 分钟内失败 10 次，该 IP 锁定 5 分钟，返回 429 `auth_rate_limited`，界面“接入”页显示被锁定的 IP。
- 回环与 LAN 下所有生成请求都必须带有效客户端令牌（内核文档 §13.2）。

### 10.6 pockettavern 连接码

为免去手机上输入长令牌，界面“接入 → pockettavern”提供“复制连接码”。

格式：`egw1:` + base64url（无填充）编码的 UTF-8 JSON：

```json
{
  "v": 1,
  "name": "GEMINI网关",
  "urls": ["http://192.168.1.23:8787/v1", "http://10.0.2.2:8787/v1"],
  "token": "egw_pt_...",
  "model": "router:chat"
}
```

- `urls`：LAN 模式下为每个候选 IPv4 地址各一条，最后追加模拟器地址 `http://10.0.2.2:<port>/v1`；回环模式下只有模拟器地址。客户端按顺序探测 `/healthz` 选第一个可达的（客户端文档 §5.3）。
- 连接码包含令牌明文。界面在复制按钮旁提示“连接码包含访问令牌，只发给自己的设备”。泄露后的影响是他人可在局域网内消耗本项目额度，不会泄露 Google Key；处理方式为重新生成 pockettavern 令牌。
- 二维码显示放在 M2（需要内嵌二维码编码实现，不引入外部服务）。

### 10.7 SillyTavern 接入信息

“接入 → SillyTavern”页展示：

| 项 | 值 |
|---|---|
| Chat Completion Source | Custom (OpenAI-compatible) |
| Custom Endpoint | 同机：`http://127.0.0.1:<port>/v1`；酒馆在 Docker Desktop：`http://host.docker.internal:<port>/v1`；其他机器：LAN 地址 |
| Custom API Key | `sillytavern` 令牌（复制按钮） |
| Model | `router:chat`（可选 `router:fast`、`router:quality`） |

其余注意事项照抄内核文档 §11.2（不要选 Google/MakerSuite、不要反复点 Test Message 等），作为页面下方的折叠说明。

---

## 十一、日志、请求记录与诊断

### 11.1 Logger

- 级别：`debug`（默认关闭）、`info`、`warn`、`error`。
- 文件：`logs\eatgemini-YYYYMMDD.log`，单文件超过 `logging.maxFileBytes` 时追加序号；保留 `logging.retentionDays` 天，启动时和每日首次写入时清理。
- 行格式：`2026-11-06T08:00:00.123Z INFO  [gateway] req_abc served model=gemini-3.8-flash attempts=2 ms=5300`。
- 每行写入前经过 Redactor（§7.3）。
- 内容范围遵守内核文档 §13.3：不记录 prompt、回复正文、Authorization、Key、完整上游错误 body。

### 11.2 请求记录

内存保留最近 `console.requestLogMemory` 条，同时追加到 `logs\requests-YYYYMMDD.jsonl`，保留天数同日志。每次请求结束写一行：

```json
{
  "requestId": "req_abc",
  "client": "pockettavern",
  "remoteIp": "192.168.1.50",
  "startedAt": "2026-11-06T08:00:00Z",
  "requestedModel": "router:chat",
  "profile": "chat",
  "stream": true,
  "outcome": "succeeded",
  "httpStatus": 200,
  "errorCode": null,
  "servedModel": "gemini-3.5-flash-lite",
  "fellBack": true,
  "attempts": [
    {"attemptId": 1, "model": "gemini-3.8-flash", "result": "failed", "status": 429, "classification": "dailyExhausted", "ms": 310},
    {"attemptId": 2, "model": "gemini-3.6-flash", "result": "skipped", "reason": "bucket_blocked"},
    {"attemptId": 3, "model": "gemini-3.5-flash-lite", "result": "succeeded", "status": 200, "ms": 5100}
  ],
  "firstEventMs": 1200,
  "totalMs": 5410,
  "usage": {"promptTokens": 5300, "completionTokens": 420, "source": "upstream"},
  "appliedTransforms": ["strip_neutral:frequency_penalty"],
  "cancelled": false
}
```

`outcome` 取值：`succeeded`、`failed_before_commit`、`failed_after_commit`、`cancelled`、`rejected_local`（本地校验/鉴权/准入拒绝，未发上游）。

### 11.3 诊断包

“诊断 → 导出”生成 `exports\eatgemini-diag-<时间戳>.json`，包含：

- 版本、构建 commit、Windows 版本、Dart 版本、Edge 路径、数据目录路径。
- 应用状态、最近一次启动检查与上游检查结果。
- `config.json` 全文（本来就不含密钥）。
- 内核状态快照（桶、模型封锁）。
- 最近 200 条请求记录、最近 500 行 `warn` 以上日志。

不包含 `secrets.dat`、任何令牌或 Key（整体再过一遍 Redactor）。导出前界面展示内容预览，用户确认后写文件，并在资源管理器中定位。程序不提供“上传诊断包”功能。

---

## 十二、构建与打包

### 12.1 界面资源内嵌

`tool/embed_assets.dart`：遍历 `assets/ui/`，生成 `lib/src/console/assets.g.dart`：

```dart
// GENERATED — do not edit.
const Map<String, EmbeddedAsset> kUiAssets = {
  '/ui/index.html': EmbeddedAsset('text/html; charset=utf-8', <int>[/* bytes */], etag: 'sha256-…'),
  // …
};
```

- 构建时如果 `assets/ui/` 中任何文件含 `http://` 或 `https://`（白名单：注释中的文档链接需改为纯文本），脚本失败（对应 §7 N2）。
- 控制台服务按路径查表返回，带 `ETag`；未知路径 404。
- 托盘图标（`.ico`）同样内嵌，运行时写入内存后通过 `CreateIconFromResourceEx` 加载。

### 12.2 编译与子系统修改

`tool/build.ps1`：

1. 读取 `tool/SDK_VERSION`，校验 `dart --version` 一致。
2. `dart run tool/embed_assets.dart`。
3. `dart test`（全部通过才继续）。
4. `dart compile exe bin/eatgemini.dart -o build/eatgemini.exe -DAPP_VERSION=<版本> -DGIT_COMMIT=<commit>`。
5. `dart run tool/set_subsystem.dart build/eatgemini.exe --gui`：
   - 读 DOS 头 `e_lfanew` → 校验 `PE\0\0` 签名 → 定位 Optional Header 的 `Subsystem` 字段（PE32+ 偏移 `0x44`）。
   - 原值必须为 `3`（`IMAGE_SUBSYSTEM_WINDOWS_CUI`），改为 `2`（`IMAGE_SUBSYSTEM_WINDOWS_GUI`）；原值不是 3 时报错退出。
   - 只改这 2 个字节，不改变文件长度，不影响 Dart 附加在文件末尾的 AOT 快照。用户态 exe 不校验 PE CheckSum。
6. `dart run tool/verify_release.dart build/eatgemini.exe`：
   - 子系统为 2。
   - 文件内不含 `AIza[0-9A-Za-z_-]{30,}`、`egw_(st|pt)_` 后跟随机串的模式（§7 N8）。
   - 启动 `eatgemini.exe --version`（GUI 子系统下版本号写入 `--version-out <file>` 指定的文件后退出），核对版本。
7. 输出 `build/eatgemini.exe` 与 `build/eatgemini.exe.sha256`。

不用 Visual Studio 的 `editbin`，避免构建机依赖 VS。

### 12.3 体积与运行依赖

- 目标体积 ≤ 20 MB。主要来源为 Dart AOT 运行时和 `timezone` 数据（只用 `latest_10y`）。
- 运行时只依赖 Windows 自带 DLL：`kernel32`、`user32`、`shell32`、`crypt32`、`advapi32`、`ws2_32`。M0 在干净的 Windows 10 虚拟机上验证无需 VC++ 运行库。

### 12.4 文件图标与签名

- M1：exe 没有自定义文件图标（资源管理器中显示默认图标），托盘和窗口图标正常。给 Dart 生成的 exe 注入图标资源（如 rcedit）会改动 PE 资源节，可能破坏末尾的 AOT 快照，M2 先验证再决定。
- M1 不签名。首次运行 Windows SmartScreen 会提示“Windows 已保护你的电脑”，用户需点“更多信息 → 仍要运行”。发布说明中写明，并附 `.sha256` 供核对。部分杀毒软件可能误报未签名的 Dart exe，发布前用 Windows Defender 扫描一次。

### 12.5 发布物

只有一个文件：`eatgemini-<版本>-windows-x64.exe`（及可选的 `.sha256`）。不附带配置、不附带说明文件；使用说明在界面“关于”页和仓库 README。

---

## 十三、监控界面

### 13.1 整体布局

```text
┌──────────────────────────────────────────────────────────────────────────┐
│ ● 运行中   网关 http://127.0.0.1:8787/v1 [复制]   今日额度重置 还有 6:42:10 │
├──────────┬───────────────────────────────────────────────────────────────┤
│ 概览      │                                                               │
│ 模型与额度 │                     （当前页面内容）                           │
│ 请求记录   │                                                               │
│ 接入      │                                                               │
│ 密钥      │                                                               │
│ 设置      │                                                               │
│ 诊断      │                                                               │
│          │                                                               │
│ [退出]    │                                                               │
└──────────┴───────────────────────────────────────────────────────────────┘
```

- 顶栏：状态圆点（颜色同 §4.3 托盘）+ 状态文字；网关地址（LAN 模式显示第一个 LAN 地址，悬停显示全部）；重置倒计时（基于 `quotaDay.nextResetAt`，同时显示北京时间，如“16:00 重置”）。
- 非 `ready` 状态时顶栏下方出现整宽提示条，带操作按钮（例如 `needs_key` →“去填写 Key”）。
- 界面文字全部中文；字体 `"Microsoft YaHei UI", "Segoe UI", system-ui`，不加载网络字体；跟随系统浅色/深色（`prefers-color-scheme`）。
- 最小窗口宽度 960px；更窄时侧栏折叠为图标。
- 前端为原生 ES Module，按页面拆文件；状态集中在 `store.js`（初始 `/api/snapshot`，之后按事件增量更新）。不使用 `innerHTML` 插入任何来自服务端的字符串，统一 `textContent`，防止上游错误信息里的 HTML 注入。

### 13.2 首次启动引导

`needs_key` 且从未保存过 Key 时，打开窗口直接进入全屏引导，三步：

1. **填写 Google API Key**：说明“在 Google AI Studio 的 API Keys 页面创建并复制。Key 只保存在这台电脑上，加密存储，只会发送给 Google 官方接口。” 表单同 §6.6。
2. **网络**：显示上一步测试中的网络结果；失败时在这里直接改代理并重测。可跳过。
3. **接入**：显示 SillyTavern 和 pockettavern 的接入信息（§10.6、§10.7），以及“手机直连需要开启局域网模式”的开关。

完成后进入概览。引导可在“密钥”页重新打开。

### 13.3 概览

| 区块 | 内容 |
|---|---|
| 服务状态卡 | 应用状态与原因；上游连通（最近检查时间、耗时，按钮“重新检查”）；监听模式与地址 |
| 今日统计 | 请求数、成功、失败、发生降级、上游实际发送次数、结果不确定次数（文案注明“本地统计，不等于 Google 官方计数”） |
| 档位卡 ×3 | `chat` / `fast` / `quality`：状态、下一个会使用的模型、可用模型数/总数；`limited` 时显示“最早 HH:mm 恢复”或“恢复时间未知” |
| 进行中 | 在途请求列表：客户端、档位、当前模型、阶段（发送中 / 等待首字 / 输出中）、已耗时；阶段随 `request.attempt` 实时变化 |
| 最近请求 | 最近 10 条，点击跳转请求记录详情 |
| 最近一小时 | 每分钟成功/失败柱状图，前端用 `<canvas>` 自绘，不引入图表库 |

### 13.4 模型与额度

表格，每行一个模型，按 `chat` 档位顺序排列：

| 列 | 内容 |
|---|---|
| 模型 | ID；`preview` 等标签 |
| 启用 | 开关（写配置） |
| 所属档位 | chat / fast / quality 标签 |
| 状态 | 可用 / 分钟限流 / 今日用完 / 疑似用完 / 无权限 / 暂停 / 未知限流 |
| 恢复时间 | 本地时间；未知显示“—” |
| RPM | 近 60 秒本地发送数 / 限额 |
| RPD | 今日本地发送数 / 限额，进度条；超过限额 80% 变黄 |
| 输入 TPM | 近 60 秒估算 / 限额 |

- 展开一行：封锁原因（`scope / dimension / evidence / confidence`，内核文档 §7）、最近 10 次尝试结果、所属配额桶 ID。
- 行操作：“清除本地估算”（只对本地估算生效；上游确认的封锁不可清，按钮禁用并说明原因）。
- 页头按钮“对账模型列表”→ `/api/router/refresh`，弹窗显示差异报告，不自动修改配置。
- 页脚固定说明：“额度数字是本机统计和 Google 返回错误的推断，以 AI Studio 页面为准。额度快照日期：<quotaSnapshot.observedAt>（未核验）。”

### 13.5 请求记录

- 表格列：时间、客户端、请求模型、实际模型、结果、HTTP 状态、尝试次数、首字耗时、总耗时、输入/输出 token。
- 筛选：客户端、结果、实际模型、时间范围；默认显示今天。
- 实时追加新请求（顶部提示“有 N 条新请求”，点击插入，避免滚动跳动）。
- 详情抽屉：attempt 时间线（每次尝试的模型、状态码、分类、耗时、跳过原因）、`appliedTransforms`、`requestId`（复制按钮，用于和客户端报错对照）。
- 页面顶部说明：“不记录对话内容。”

### 13.6 接入

- 监听模式：单选“仅本机” / “局域网（手机直连需要）”，切换即热重绑（§8.4）；端口输入框 + “应用”。
- SillyTavern 卡：§10.7 表格，每项带复制按钮；令牌默认遮挡，“显示”调用 reveal 接口。
- pockettavern 卡：
  - 地址列表（每个网卡一行，标网卡名）+ 模拟器地址。
  - 访问令牌（显示 / 复制 / 重新生成）。
  - “复制连接码”按钮及 §10.6 的提示。
  - 简要步骤：“pockettavern → 设置 → AI 服务 → 连接档案 → GEMINI网关 → 粘贴连接码 → 测试 → 启用”。
- “最近连接”：每个客户端最近一次请求的时间和来源 IP，用于确认手机已经连上。
- 被鉴权限流锁定的 IP 列表（§10.5），可手动解除。

### 13.7 密钥

- 上游 Key：来源、遮挡值、添加时间、最近验证时间与结果；按钮“更换”“重新验证”“删除”。
- 客户端令牌：与“接入”页同一组件。
- 说明区：“Key 用 Windows 数据保护（DPAPI）加密保存在 `%LOCALAPPDATA%\eatgemini\secrets.dat`，只有当前 Windows 用户能解开；换电脑或重装系统后需要重新填写。程序只会把 Key 发送给 <upstream host>。”

### 13.8 设置

| 分组 | 项 |
|---|---|
| 网络代理 | 模式（无 / 环境变量 / 手动）、主机、端口、“测试上游连通” |
| 路由 | 默认档位；三个档位的模型顺序（拖拽排序，保存时校验）；“高级”折叠区：内核 `policy` 中的预算与超时，每项带说明和“恢复默认” |
| 上游 | baseUrl（修改时按 §7.2 警告）；连接/首事件/空闲超时 |
| 界面 | 启动时打开窗口；窗口方式（自动 / 默认浏览器） |
| 日志 | 保留天数；调试日志开关（开启时顶栏显示“调试日志已开启”） |
| 数据 | 打开数据目录；重新加载配置；恢复默认配置；清除全部本地数据（需输入“清除”确认，删除后程序退出） |

### 13.9 诊断

版本与构建信息、数据目录、Edge 路径、代理模式（脱敏）、最近一次启动检查各步骤结果、最近 `warn` 以上日志（只读滚动列表）、“导出诊断包”（§11.3）。

---

## 十四、托盘

- 实现：独立 isolate 中创建**隐藏的顶层工具窗口**（`WS_POPUP` + `WS_EX_TOOLWINDOW`，从不 `ShowWindow`）、`Shell_NotifyIconW(NIM_ADD)`、`GetMessageW` 循环。与主 isolate 通过 `SendPort` 交换消息：主 → 托盘 `{state, tooltip}`；托盘 → 主 `{action}`。不用 message-only 窗口（`HWND_MESSAGE`）：它不在 Z 序里，`SetForegroundWindow` 永远失败，KB135788 菜单焦点修复无法生效（右键菜单「不跟手」），也收不到 `TaskbarCreated` 广播。
- 图标版本用 `NOTIFYICON_VERSION_4`（`NIM_SETVERSION`）：v0/v3 的鼠标 UP 被 Shell 扣住 `GetDoubleClickTime` 做双击判定（实测 ~500ms），v4 的消息即时投递。v4 下 lParam 为 `MAKELONG(事件, 图标ID)`；标准 tooltip 被抑制，`NIF_TIP` 搭配 `NIF_SHOWTIP`。
- 点击在 WndProc 里**同步**处理（右键当场 `TrackPopupMenu`，双击当场转发打开）：经事件循环中转会被鼠标消息洪峰拖慢数百 ms。防菜单重开：模态期间 `_menuTracking` + 关闭后 400ms 内视为点击回放。
- 图标折叠/可见完全遵循 Windows 任务栏设置，应用不改写 `NotifyIconSettings\IsPromoted`。
- 处理 `TaskbarCreated` 广播消息：Explorer 重启后重新 `NIM_ADD`。
- 提示文字：`eatgemini · 运行中 · 今日 42 次`（≤ 127 字符）。
- 双击：打开监控窗口（单击不动作）。
- 右键菜单：

```text
打开监控窗口
复制网关地址
──────────
状态：运行中（只读）
──────────
退出 eatgemini
```

- 气泡通知（`NIIF_INFO` / `NIIF_WARNING`）只在三种情况出现：首次关闭窗口（§4.4）、进入 `persist_error`/`port_conflict`/`config_error`、上游 Key 验证失败（401）。额度用完不弹气泡，避免打扰。

---

## 十五、代码结构与模块接口

### 15.1 目录

在内核文档 §4 的结构上增加（内核目录不变）：

```text
eatgemini/
├─ bin/eatgemini.dart              入口：参数、runZonedGuarded、AppController.run()
├─ lib/src/
│  ├─ core/ quota/ http/            内核（内核文档 §4）
│  ├─ adapters/                     内核的 dart:io Transport、文件 StateStore
│  ├─ app/
│  │  ├─ app_controller.dart        §4.2 启动编排、§4.5 退出
│  │  ├─ app_state.dart             §4.3 状态机
│  │  ├─ app_facade.dart            控制台调用的唯一入口（便于假实现测试）
│  │  ├─ config_store.dart          config.json 读写、v2→v3 迁移、revision
│  │  ├─ data_dir.dart              §5 路径解析
│  │  └─ single_instance.dart       互斥体 + instance.json + /ipc/show 客户端
│  ├─ secrets/
│  │  ├─ dpapi.dart                 CryptProtectData/CryptUnprotectData FFI
│  │  ├─ secret_vault.dart          §6 读写、失败恢复、遮挡 toString
│  │  └─ upstream_verifier.dart     §6.6 Key 测试
│  ├─ net/
│  │  ├─ egress_guard.dart          §7.2
│  │  ├─ proxy_config.dart          §8.3
│  │  └─ lan_addresses.dart         §10.5 网卡枚举
│  ├─ gateway_ext/
│  │  ├─ healthz.dart               §10.1
│  │  ├─ router_status.dart         §10.3
│  │  └─ auth_rate_limiter.dart     §10.5
│  ├─ console/
│  │  ├─ console_server.dart        §9.1–§9.3
│  │  ├─ api_routes.dart            §9.4
│  │  ├─ event_stream.dart          §9.5
│  │  ├─ connect_code.dart          §10.6
│  │  └─ assets.g.dart              §12.1 生成文件
│  ├─ desktop/
│  │  ├─ browser_launcher.dart      §4.4
│  │  ├─ tray_isolate.dart          §14
│  │  └─ win_dialogs.dart           MessageBox
│  └─ observe/
│     ├─ logger.dart                §11.1
│     ├─ redactor.dart              §7.3
│     ├─ request_log.dart           §11.2
│     ├─ event_bus.dart
│     └─ diagnostics.dart           §11.3
├─ assets/ui/                       index.html、app.css、js/*.js、icons/
├─ tool/
│  ├─ SDK_VERSION
│  ├─ build.ps1
│  ├─ embed_assets.dart
│  ├─ set_subsystem.dart
│  └─ verify_release.dart
└─ test/
   ├─ (内核测试)
   └─ desktop/                      §17 的 D 系列
```

依赖方向：`desktop`、`secrets/dpapi` 是仅有的使用 `win32`/`ffi` 的目录；`console` 只依赖 `app_facade`，不直接 import 内核或 vault；内核不 import 本节任何新目录。

### 15.2 关键接口

```dart
abstract interface class SecretVault {
  Future<VaultLoadResult> load();            // ok / missing / unreadable(renamedTo)
  UpstreamKeyInfo get upstream;              // configured, source, masked, addedAt…
  ApiKey? get upstreamKey;                   // toString() 返回遮挡值
  ClientToken token(String clientId);
  Future<void> setUpstreamKey(ApiKey key, {required VerifyResult verify});
  Future<void> deleteUpstreamKey();
  Future<ClientToken> rotateToken(String clientId);
  Stream<SecretsChange> get changes;
}

abstract interface class Dpapi {
  Uint8List protect(Uint8List plain, Uint8List entropy);
  Uint8List unprotect(Uint8List blob, Uint8List entropy); // 失败抛 DpapiException
}

abstract interface class EgressPolicy {
  void check(Uri target);                    // 不在白名单抛 EgressDenied，必须在建立连接前调用
}

abstract interface class Redactor {
  String redact(String input);
  void registerSecret(String value, String label);
}

abstract interface class AppFacade {
  AppSnapshot snapshot();
  Stream<AppEvent> events();
  Future<VerifyResult> verifyUpstreamKey(String rawKey);
  Future<SaveKeyResult> saveUpstreamKey(String rawKey, {required bool sameProject, String? projectRef});
  Future<void> deleteUpstreamKey();
  Future<ConfigWithRevision> readConfig();
  Future<ConfigWriteResult> writeConfig(int revision, Map<String, Object?> config);
  Future<RebindResult> rebind(ListenConfig listen);
  ConnectInfo connectInfo();
  String revealToken(String clientId);
  Future<String> rotateToken(String clientId);
  String pockettavernConnectCode();
  Future<UpstreamCheck> checkUpstream();
  Future<RefreshReport> refreshModels();
  Future<void> clearLocalEstimate(String bucketId);
  RequestPage requests(RequestQuery q);
  RequestDetail? request(String requestId);
  Future<File> exportDiagnostics();
  Future<void> exit();
}

abstract interface class BrowserLauncher {
  Future<LaunchResult> open(Uri url);        // edge / chrome / shell，返回实际方式
}

abstract interface class Tray {
  Future<void> start(SendPort toMain);
  void update(TrayState state, String tooltip);
  void balloon(String title, String text, {bool warning = false});
  Future<void> dispose();
}
```

所有 FFI 实现都有对应的假实现（`FakeDpapi` 用 XOR + 校验和模拟、`FakeBrowserLauncher` 记录调用），使 `test/desktop` 能在 CI 的非 Windows 环境下运行除 `dpapi_windows_test.dart`、`tray_windows_test.dart` 以外的全部用例。

---

## 十六、里程碑

| 阶段 | 内容 | 完成标准 |
|---|---|---|
| **M0 技术验证**（1–2 天） | ① GUI 子系统 Dart exe：HttpServer、Process.start、isolate、未捕获异常、残留 stdout 写入 ② DPAPI 往返；换用户/换机器解密失败的表现 ③ Edge `--app` + 独立 user-data-dir；关闭检测；无 Edge 回退 ④ 托盘 isolate：消息循环、菜单、Explorer 重启、退出时图标移除 ⑤ 互斥体 + `/ipc/show` ⑥ 绑定 `0.0.0.0` 时防火墙弹窗行为 ⑦ Windows 下 tmp→正式文件替换 ⑧ 干净 Win10 虚拟机运行 | 每项写验证记录（截图或日志）；①失败则切换到 `FreeConsole()` 备选方案并记录 |
| **M1 桌面 MVP**（内核 P1 完成后 5–7 天） | §4–§14 全部，不含标注 M2 的项 | §17 D1–D24 通过；内核 A/B 系列不回退 |
| **M2 增强** | 二维码、系统代理读取、开机自启（`HKCU\…\Run`）、便携模式、exe 图标、WebView2 内嵌窗口评估、代码签名 | 分项验收 |

M1 的前提是内核文档 P1 的网关已可用；M0 可与内核 P0/P1 并行。

---

## 十七、验收用例

D 系列为桌面版用例；内核文档 A1–A20、B1–B15 继续有效。

| # | 场景 | 预期 |
|---|---|---|
| D1 | 干净 Win10/11 虚拟机，双击 exe | 3 秒内出现监控窗口，全程无控制台窗口；无需安装任何运行库 |
| D2 | 程序已运行，再次双击 exe | 不产生第二个网关进程；已有实例打开窗口；第二个进程退出 |
| D3 | 首次启动 | 进入引导页；此时客户端调用生成接口得到 503 `gateway_needs_key`，`/healthz` 正常 |
| D4 | 填写错误 Key | 测试返回“Key 无效”，不保存；抓包/假上游确认只发生 `GET models`，无生成请求 |
| D5 | 填写正确 Key | 保存成功，状态进入 `ready`；`secrets.dat` 中搜不到 Key 明文；`config.json` 不含 Key |
| D6 | 把 `secrets.dat` 复制到另一个 Windows 用户下启动 | 进入 `needs_key`，原文件被改名保留，界面显示 §6.3 提示 |
| D7 | 假上游在错误 message 中回显 Key 和令牌 | 下游错误响应、SSE error、日志、请求记录、诊断包中都只有 `[REDACTED:…]` |
| D8 | 修改 baseUrl 为非 Google 主机 | 必须勾选确认才能保存；任何非白名单出站（包括代码中故意构造的请求）在连接前被拒绝 |
| D9 | 控制台 API 安全 | 无 Cookie 401；错误 Host 421；非 GET 缺 Origin 或 CSRF 头 403；启动票据第二次使用失效；从局域网访问控制台端口连接被拒（只绑回环） |
| D10 | LAN 模式 | 手机用 pockettavern 令牌成功；用 sillytavern 令牌也可（权限按 clientId）；无令牌 401；同 IP 连续错 10 次后 429 并在界面可见 |
| D11 | 关闭监控窗口 | 网关继续服务；首次出现托盘气泡；托盘双击可重新打开 |
| D12 | 托盘退出，期间有流式请求 | 10 秒内退出；在途流收到 SSE error 后关闭；`instance.json` 删除；再次启动正常 |
| D13 | 8787 被占用 | 进入 `port_conflict`；界面改端口后无需重启即可服务 |
| D14 | 界面修改配置与并发修改 | 无效配置被拒且原配置不变；旧 revision 写入返回 409；在途请求使用旧快照完成 |
| D15 | 实时监控 | 发起请求后 1 秒内在“进行中”出现；降级时阶段与模型变化可见；结束后进入请求记录 |
| D16 | 重置倒计时 | 使用假时钟跨 PT 午夜及夏令时切换日，倒计时与北京时间显示正确 |
| D17 | 代理三种模式 | 每种模式下“测试上游连通”结果分阶段准确；代理凭据在诊断中被遮挡 |
| D18 | 删除 Key | 在途请求完成，新请求 503 `gateway_needs_key` |
| D19 | 重新生成 pockettavern 令牌 | 旧令牌立即 401 `invalid_client_token`；新连接码可用 |
| D20 | 诊断导出 | 预览与文件内容一致；不含任何密钥；文件只写到 `exports\` |
| D21 | 进程被强制结束后重启 | 识别残留 `instance.json`（pid 不存在）并覆盖；内核未结算预留标为 uncertain |
| D22 | 系统中无 Edge | 用默认浏览器打开并显示提示 |
| D23 | 发布物检查 | 子系统为 GUI；不含开发者 Key；界面资源无外链；体积 ≤ 20 MB |
| D24 | `/healthz`、`/router/status`、`/v1/models` 扩展字段 | 结构与 §10 一致；`/router/status` 不含项目、Key、代理信息；未知限额字段缺省而非填 0 |

---

## 十八、风险

| 风险 | 影响 | 应对 |
|---|---|---|
| GUI 子系统下 Dart 运行时行为异常 | 启动失败或卡死 | M0 验证；备选 `FreeConsole()` |
| Edge 被组策略禁用或 `--app` 无效 | 没有独立窗口 | 回退默认浏览器；界面完全在浏览器标签中可用 |
| 未签名 exe 被 SmartScreen/杀毒拦截 | 用户无法启动 | 发布说明写明操作；附 sha256；M2 评估签名 |
| 用户重装系统或换电脑 | Key 无法解密 | 设计如此；§6.3 引导重新填写 |
| 局域网模式被同网他人访问 | 消耗额度 | 必须令牌、失败限流、界面提示仅专用网络；令牌可一键作废 |
| 托盘 isolate 与主 isolate 同步问题 | 图标残留或菜单无响应 | 退出时先 `NIM_DELETE` 再结束 isolate；处理 `TaskbarCreated` |
| Dart 内存中的密钥无法清零 | 内存转储可读出 Key | 不承诺内存擦除，文档写明；只保证不出进程 |
| 用户把连接码发给别人 | 他人可用额度 | 界面提示；重新生成令牌即可作废 |

