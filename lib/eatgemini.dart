/// 对外导出：内核与桌面层的公共类型，便于测试与未来复用。
library;

export 'src/adapters/transport.dart';
export 'src/app/app_controller.dart';
export 'src/app/app_env.dart';
export 'src/core/chat.dart';
export 'src/core/classify.dart';
export 'src/core/config.dart';
export 'src/core/pacific_clock.dart';
export 'src/core/router_engine.dart';
export 'src/core/telemetry.dart';
export 'src/http/sse.dart';
export 'src/observe/observability.dart';
export 'src/quota/quota.dart';
export 'src/secrets/vault.dart';
