# eatgemini Bug 修复清单（2026-11-09）

> 范围：`g:\game\nw\eatgemini` 全项目只读排查结论汇总。
> 本清单仅记录已确认的问题，未包含推测项；排查过程未修改任何业务代码。
>
> 状态（v0.2.3）：25 项均已修复，回归测试已加入 `test/`；复测 `dart analyze` 0 问题、147 个测试全过。

## 一、概览

### 1.1 数量统计

| 等级 | 数量 | 编号区间 |
| --- | --- | --- |
| 阻断 | 0 | — |
| 严重 | 3 | S1 – S3 |
| 一般 | 14 | G1 – G14 |
| 轻微 | 8 | M1 – M8 |
| **合计** | **25** | — |

### 1.2 当前静态检查与测试状态

| 检查项 | 命令 | 结果 |
| --- | --- | --- |
| 静态检查 | `.tools\dart-sdk\bin\dart.exe analyze` | **No issues found** |
| 单元测试 | `.tools\dart-sdk\bin\dart.exe test` | **114 个测试全部通过** |

说明：

- 本项目是**纯 Dart 桌面程序**（非 Flutter 工程），仓库自带 `.tools/dart-sdk`，因此用 `dart analyze` / `dart test` 完成检查，无环境阻塞。
- 现有测试集中在正常路径，未覆盖并发准入、客户端断连、上游响应体卡住等异常路径，下列问题均未被测试捕获。

### 1.3 建议修复顺序

1. **S1 + S3**：取消链路与并发准入计数，直接影响额度消耗与多客户端并发正确性。
2. **S2**：上游响应体读取加超时与兜底，保证 `request.finished` 一定发出，避免请求槽位泄漏。
3. **G1 + G2**：状态误报与局域网接入地址，属用户直接可见问题。
4. **G3 – G7**：配额探测、日志/状态文件、transport 资源泄漏，影响长期运行稳定性。
5. **G8 – G14**：安全与配置边界问题。
6. **M1 – M8**：按需清理。

---

## 二、严重

- [ ] **S1 · 客户端断开/停止生成后，上游生成不会被中止**
  - 位置：[gateway_server.dart](../lib/src/http/gateway_server.dart#L529-L552)、[router_engine.dart](../lib/src/core/router_engine.dart#L21-L27)
  - 问题简述：`AbortToken` 提供了 `whenAborted`，但全仓库仅在写响应失败后的 `catch` 里调用 `token.abort()`（L548）；没有监听 `response.done` / 连接关闭。流式中继的 `await for (final chunk in r.body)` 循环里也不检查 `isAborted`。
  - 影响：SillyTavern 停止生成、关闭页签或断网后，网关仍持续读上游 SSE，继续消耗本就很紧的额度；`RouteErrorResult` 的 499 / cancelled 分支基本不可达。思考型模型首帧耗时较长时最明显。
  - 建议修复：在 `_handleChat` 中订阅下游响应关闭/异常并 `token.abort()`；中继循环每轮检查 `isAborted` 并退出；把 `whenAborted` 接入流读取等待逻辑。

- [ ] **S2 · 上游响应体读取无超时；非 200 响应体读取异常会让请求变 500 并泄漏在途状态**
  - 位置：[router_engine.dart](../lib/src/core/router_engine.dart#L681-L690)、[router_engine.dart](../lib/src/core/router_engine.dart#L1256-L1277)、[app_controller.dart](../lib/src/app/app_controller.dart#L508-L520)、[app_controller.dart](../lib/src/app/app_controller.dart#L1043-L1056)
  - 问题简述：`_readLimited` / `_readLimitedBytes` 只是 `await for` 读流，没有 `.timeout`；L741 的 `on TimeoutException`（“等待上游完整响应超时”）因此近乎死代码。非 200 分支（L682）读取响应体时没有 try/catch，网络重置或解码异常会抛出 `_attempt`，最终被兜底成 500。异常路径不会发出 `request.finished`。
  - 影响：上游“发完响应头后卡住不吐 body”时非流式请求会永久挂起；异常请求在 `_inflight`（[app_controller.dart L509](../lib/src/app/app_controller.dart#L509)）中永久残留，退出时 `shutdown` 会多等至多 10 秒，配额也不会被 `markUncertain` 结算。
  - 建议修复：给两处响应体读取加剩余预算超时并分别包 try；`_attempt` 调用点统一兜底；`_handleChat` 用 `finally` 保证 summary / finished 必发。

- [ ] **S3 · 并发准入按客户端计数错误，`maxQueueLengthPerClient` 未生效，流式请求提前释放名额**
  - 位置：[gateway_server.dart](../lib/src/http/gateway_server.dart#L450-L489)、[gateway_server.dart](../lib/src/http/gateway_server.dart#L764-L810)
  - 问题简述：`acquire` 接收 `maxQueuePerClient` 但从未使用；`release(clientId)` 唤醒等待者时用**释放方**的 clientId 调 `_take`，被唤醒者可能是另一客户端。并且 `_admission.release` 在 `route()` 返回后的 `finally` 执行，此时流式请求才刚提交首帧。
  - 影响：多客户端长期运行后 `_perClient` 计数漂移，出现“空闲却一直排队”或“突破单客户端并发上限”；`maxInFlight` 无法约束整个 SSE 生命周期，并发流仍可打满上游。
  - 建议修复：等待队列记录 `clientId + Completer`，唤醒时按该客户端 ID 重新判定并 `_take`；流式请求把 release 移到中继结束的 `finally`（或拆分“全局并发”和“取首帧并发”两个信号量）。

---

## 三、一般

- [ ] **G1 · 配置损坏恢复成功后 `config_error` 不会自动清除，备份也不会写回**
  - 位置：[app_controller.dart](../lib/src/app/app_controller.dart#L131-L149)、[app_controller.dart](../lib/src/app/app_controller.dart#L280-L294)、[app_env.dart](../lib/src/app/app_env.dart#L83-L90)
  - 问题简述：`tryRecover()` 成功后仍保持 `_configError = true`；只有手动 `reloadConfig()`（L778）或 `resetConfig()`（L789）才会清零。`tryRecover()` 只读取 `.bak`，不会把内容写回 `config.json`。
  - 影响：每次启动都命中坏配置并重复走恢复流程；UI / 托盘长期显示“配置无效”，`/readyz` 持续 503，直到用户手动保存一次配置。
  - 建议修复：恢复成功即清除错误状态并把配置落盘（同时把坏文件改名为 `.corrupt` 保留）。

- [ ] **G2 · LAN 模式冷启动时局域网地址为空**
  - 位置：[app_controller.dart](../lib/src/app/app_controller.dart#L478-L501)、[app_controller.dart](../lib/src/app/app_controller.dart#L614-L626)
  - 问题简述：`_lanCache` 只在 `setListen()`（L1019）里刷新，`start()` 启动流程中从未调用 `refreshLanAddresses()`，与字段注释“启动时刷新一次”不一致。
  - 影响：配置已是 LAN 模式时冷启动，`/api/snapshot` 的 PocketTavern 地址只剩 `10.0.2.2`（Android 模拟器专用），真实手机拿不到 `http://192.168.x.x:端口/v1`，需用户重新保存一次接入设置。
  - 建议修复：启动时（绑定网关成功后）主动 `await refreshLanAddresses()`。

- [ ] **G3 · RPD 探测节流只生效一次**
  - 位置：[quota.dart](../lib/src/quota/quota.dart#L389-L402)、[quota.dart](../lib/src/quota/quota.dart#L437-L443)
  - 问题简述：`_checkBucket` 用 `lastProbeMs` 做间隔判断，但 `reserve()` 只在 `lastProbeMs == null` 时写入时间戳，之后不再更新。
  - 影响：首次探测后经过一个 interval，此后所有 `allowProbe` 请求都会放行，`quotaProbeIntervalMs` 形同虚设；探测流量会持续打到上游直到 429。
  - 建议修复：每次放行探测时更新 `lastProbeMs = nowMs`。

- [ ] **G4 · RPD 桶的 `minuteEvents` 只增不减且被持久化**
  - 位置：[quota.dart](../lib/src/quota/quota.dart#L430-L445)、[quota.dart](../lib/src/quota/quota.dart#L407-L411)、[quota.dart](../lib/src/quota/quota.dart#L269-L288)
  - 问题简述：`reserve()` 对所有维度都 `minuteEvents.add(nowMs)`，但 `_pruneMinute` 只在 rpm / tpm 的检查路径调用（L374、L380），`rollover()` 也不清 `minuteEvents`。
  - 影响：后台长跑时 RPD 桶的分钟事件持续累积并写入状态文件，文件膨胀、加载变慢，跨天也不回收。
  - 建议修复：rpd 桶不做分钟事件记账，或在 `rollover()` 与 `reserve()` 中统一 prune。

- [ ] **G5 · 请求明细 `_attempts` 无上界，首条请求明细丢失，`cleanupOld()` 从未调用**
  - 位置：[observability.dart](../lib/src/observe/observability.dart#L174-L197)、[observability.dart](../lib/src/observe/observability.dart#L227-L236)
  - 问题简述：`_entries` 有 500 条环形上限，但 `_attempts` 以 requestId 为键只 put 不删；`noteAttempt` 在 `_entries.isEmpty` 时直接 return；`RequestLog.cleanupOld()` 全仓库无调用点。
  - 影响：进程级内存随请求量单调增长；进程启动后第一条请求的尝试明细永远缺失；`requests-*.jsonl` 永久堆积，`logging.retentionDays` 对请求日志不生效。
  - 建议修复：`_attempts` 随 `_entries` 淘汰同步清理或设上限；去掉 `_entries.isEmpty` 的提前返回；在启动/定时任务中调用 `cleanupOld()`。

- [ ] **G6 · 每次改配置都新建 transport，旧 HttpClient 从不关闭**
  - 位置：[app_controller.dart](../lib/src/app/app_controller.dart#L249-L263)、[transport.dart](../lib/src/adapters/transport.dart#L188-L213)
  - 问题简述：`_rebuildCore()` 直接 `new DartIoTransport(...)`，没有关闭旧实例；`Transport` 也没有 `close()` 接口。该方法在保存配置、切换模型、写/删 Key、轮换令牌等处反复调用。
  - 影响：旧 `HttpClient` 的 keep-alive 连接与内部资源无人释放，连续操作后连接数堆积（属资源泄漏）。
  - 建议修复：`Transport` 增加 `close()`，`_rebuildCore` 延迟关闭旧实例（等在途请求结束）。

- [ ] **G7 · 代理值丢失 scheme，SOCKS / TLS / 认证代理全部连错**
  - 位置：[transport.dart](../lib/src/adapters/transport.dart#L106-L127)、[transport.dart](../lib/src/adapters/transport.dart#L130-L160)
  - 问题简述：`normalizeProxyValue` 把 `socks5://host:port`、`https://host:port`、`http://user:pass@host:port` 一律规范成 `host:port`，再统一拼成 `PROXY host:port`。
  - 影响：配置 SOCKS5（Clash 常见默认）时会用 HTTP 代理协议连 SOCKS 端口，所有上游请求失败；需要认证的代理必然 407。
  - 建议修复：保留 scheme，映射为 `SOCKS5 host:port` / `PROXY host:port`；认证代理给出明确错误提示。

- [ ] **G8 · 控制台 `/ui/` 磁盘回退存在路径穿越**
  - 位置：[server.dart](../lib/src/console/server.dart#L526-L545)
  - 问题简述：`key.replaceFirst('/ui/', '')` 后直接拼 `File('assets/ui/$rel')`，未做 `..` 归一化校验。
  - 影响：持有有效控制台会话 Cookie 时，`/ui/../../pubspec.yaml` 之类请求可读取项目目录内任意文件（本地任意文件读取）。
  - 建议修复：先用 `Uri` 归一化，再校验最终路径位于 `assets/ui` 目录内（`p.isWithin`）。

- [ ] **G9 · 端口 / 绑定地址未校验，且网关“先停后绑”失败不回滚**
  - 位置：[app_controller.dart](../lib/src/app/app_controller.dart#L230-L247)
  - 问题简述：`_startGateway` 只捕获 `SocketException`，非法 bind 地址会抛 `ArgumentError`；`gatewayStart()` 先 `stop()` 再 `start()`，绑定失败后网关处于已停止状态，而 `_portError` 仍为 false。
  - 影响：手改 `config.json` 或未来 UI 支持自定义地址/端口（如 70000）时，应用状态会误报 `ready`，实际网关未监听。
  - 建议修复：配置层校验端口范围与地址格式；`_startGateway` 捕获全部异常并置错误状态；绑定失败时尝试恢复上一次监听配置。

- [ ] **G10 · “今日统计”口径错误，`startedAt` 每次都填当前时间**
  - 位置：[app_controller.dart](../lib/src/app/app_controller.dart#L306-L311)、[app_controller.dart](../lib/src/app/app_controller.dart#L334-L356)
  - 问题简述：`_todayStats()` 统计内存中全部（最多 500 条、可跨天）记录，`uncertainAttempts` 硬编码为 0；`app.startedAt` 每次快照都写 `now`。
  - 影响：跨天后“今日”数据虚高且被 500 条截断；UI 永远显示“刚刚启动”。
  - 建议修复：记录真实启动时间；按太平洋日期过滤统计；`uncertainAttempts` 从 summary 汇总。

- [ ] **G11 · 首个 SSE 事件为 `error` 帧时不取消上游连接**
  - 位置：[router_engine.dart](../lib/src/core/router_engine.dart#L786-L792)
  - 问题简述：该分支直接 `return _AttemptFailure(...)`，没有 `iterator.cancel()` / `response.cancel()`；相邻的超时与异常分支（L813-L831）均有取消。
  - 影响：旧连接与未读完的 SSE 缓冲继续挂起，占用连接和内存，加重 S2 的挂起风险。
  - 建议修复：在该分支补 `await iterator.cancel(); await response.cancel();`。

- [ ] **G12 · `StaticTokenDirectory` 多令牌时永远认证失败（潜在）**
  - 位置：[telemetry.dart](../lib/src/core/telemetry.dart#L90-L111)
  - 问题简述：`diff |= localDiff` 会把所有条目的差异累加，只要库中存在任意一个不匹配令牌，即使另一个完全匹配也返回 null。生产使用的 `_VaultTokenDirectory`（[app_controller.dart L1203-L1224](../lib/src/app/app_controller.dart#L1203-L1224)）实现正确，因此目前仅在测试 / 导出 API 中可触发。
  - 影响：后续新增令牌时，`StaticTokenDirectory` 场景下所有令牌都会认证失败。
  - 建议修复：每个条目独立判断，命中即返回，不要跨条目累加 `diff`。

- [ ] **G13 · 切换项目时不清理 `_projectBlockedUntilMs`**
  - 位置：[quota.dart](../lib/src/quota/quota.dart#L229-L266)
  - 问题简述：`load()` 在 `raw == null` 或项目不一致时提前返回，只清 `_buckets` / `_models`，不清项目级封锁状态。
  - 影响：`quarantineStateForNewProject` 先重命名状态文件再 `load()`，旧项目的项目级封锁会带到新项目，表现为新项目一上来就 `project_blocked`。
  - 建议修复：提前返回前同时重置 `_projectBlockedUntilMs` 与 `_projectReason`。

- [ ] **G14 · `clearAllLocalEstimates` 会清掉模型级 cooldown 与项目级封锁**
  - 位置：[quota.dart](../lib/src/quota/quota.dart#L633-L647)
  - 问题简述：桶级 `confirmedBlockedUntilMs` 确实被保留（L635 `continue`），但 `_models.clear()` 会抹掉模型级 cooldown / 学习到的参数剥离，`_projectBlockedUntilMs` 也被置空，与“只清本地估算”的语义不符。
  - 影响：一旦接入控制台操作，会丢失模型级与项目级的上游限流事实，随后立刻再次触发 429。
  - 建议修复：只清桶级本地估算字段（`localAttempts` / `lastProbeMs` / 疑似封锁），保留模型级状态与项目级封锁。

---

## 四、轻微

- [ ] **M1 · 托盘握手存在竞态，可能每次启动多等 3 秒**
  - 位置：[tray_coordinator.dart](../lib/src/desktop/tray_coordinator.dart#L70-L96)
  - 问题简述：`_readyCompleter = ready` 在 `await Isolate.spawn(...)` **之后**才赋值；isolate 若抢先发出 ready 消息，`_readyCompleter` 仍为 null，后续 complete 丢失。
  - 影响：握手超时 3 秒并记录误报日志，启动变慢。
  - 建议修复：先创建 completer，再 `spawn`。

- [ ] **M2 · `desktop.browser` 的 `edge` / `chrome` 选择被忽略**
  - 位置：[browser_launcher.dart](../lib/src/desktop/browser_launcher.dart#L11-L69)
  - 问题简述：仅区分 `default` 与“非 default”，非 default 时统一走 `_findBrowser()`，按固定顺序（Edge 优先）查找，未按配置值选择。
  - 影响：用户配置 `chrome` 但机器同时装了 Edge 时，仍会启动 Edge。
  - 建议修复：按 `preferred` 值挑选对应可执行文件，找不到时再回退。

- [ ] **M3 · 流式 usage / 错误码按 TCP chunk 嗅探，跨块时静默丢失**
  - 位置：[gateway_server.dart](../lib/src/http/gateway_server.dart#L538-L544)、[gateway_server.dart](../lib/src/http/gateway_server.dart#L637-L683)
  - 问题简述：`_sniffUsage` / `_sniffStreamError` 对每个 chunk 直接 `utf8.decode` 后按行解析；SSE 帧被 TCP 切块时 `jsonDecode` 抛异常并被吞掉，后续块也没有 `data: ` 前缀。
  - 影响：流式请求的 token 统计与 `streamErrorCode` 偶发缺失，影响报表和额度估算。
  - 建议修复：维护跨块行缓冲，按完整行解析。

- [ ] **M4 · 启动时创建两个 EventBus，第一个被丢弃**
  - 位置：[app_controller.dart](../lib/src/app/app_controller.dart#L99-L117)
  - 问题简述：`bus = EventBus()` 在 L100 与 L117 各执行一次，L101 的 logger 回调通过字段动态解析，功能正常，但第一个实例无人引用也未 close。
  - 影响：轻微资源浪费与代码歧义，无功能故障。
  - 建议修复：删除 L100 的重复创建。

- [ ] **M5 · `_printSink` 从未赋值，print 输出被吞**
  - 位置：[eatgemini.dart](../bin/eatgemini.dart#L16-L17)、[eatgemini.dart](../bin/eatgemini.dart#L44-L66)
  - 问题简述：注释称“由 AppController 设置”，但仓库内没有任何赋值点；zone 的 `print` 只调用 `_printSink?.call(line)`，无控制台模式下额外丢弃。
  - 影响：库内 `print`、未捕获异常提示在无控制台模式下完全不可见，排查困难。
  - 建议修复：在 Logger 就绪后赋值 `_printSink`（写入日志文件），或移除该间接层。

- [ ] **M6 · 状态文件备份只在首次成功，`.bak` 长期过期**
  - 位置：[app_controller.dart](../lib/src/app/app_controller.dart#L1245-L1262)
  - 问题简述：`if (_file.existsSync()) rename('.bak')` 在 `.bak` 已存在时失败并被 `catch` 吞掉，残留旧备份不会被替换。
  - 影响：断电 / 崩溃后恢复的是很久以前的状态，配额估算回退。
  - 建议修复：先删除旧 `.bak` 再 rename，或使用带时间戳的滚动备份。

- [ ] **M7 · `stripParams` 对 `stop` 不生效**
  - 位置：[router_engine.dart](../lib/src/core/router_engine.dart#L539-L570)
  - 问题简述：`_buildBody` 里 `stop` 只判断 `repairs.contains('stop')`，未判断 `spec.stripParams.contains('stop')`，与其他参数的处理不一致。
  - 影响：为特定模型手工配置剥离 `stop` 无效。
  - 建议修复：条件改为 `!spec.stripParams.contains('stop') && !repairs.contains('stop')`。

- [ ] **M8 · `releaseUnsent` 可能删掉其他请求的分钟事件**
  - 位置：[quota.dart](../lib/src/quota/quota.dart#L459-L474)
  - 问题简述：对共享桶执行 `b.minuteEvents.removeLastWhere((_) => true)`，不校验事件归属。
  - 影响：并发下释放未发送预留时，可能把另一请求的计数删掉，导致 RPM 统计偏低。
  - 建议修复：按预留时间戳精确移除，或在 Reservation 中记录写入的事件索引。

---

## 五、备注

- 本清单与静态检查 / 测试结果均基于 2026-11-09 的代码状态。
- 修复时建议每条单独提交，并在修复后补充对应异常路径的测试（取消、超时、并发准入、响应体中断）。
