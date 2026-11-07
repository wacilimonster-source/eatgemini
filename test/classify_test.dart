import 'package:eatgemini/src/core/classify.dart';
import 'package:eatgemini/src/core/config.dart';
import 'package:test/test.dart';

void main() {
  UpstreamFailure classify(
    int status,
    String body, {
    Map<String, String> headers = const {},
  }) =>
      classifyUpstreamError(status: status, headers: headers, body: body);

  test('429 明确每日配额 → dailyExhausted', () {
    final f = classify(429, '''
{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"Quota exceeded",
"details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[
{"quotaMetric":"generativelanguage.googleapis.com/generate_content_free_tier_requests",
"quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier","limit":20}]}]}}
''');
    expect(f.kind, FailureKind.dailyExhausted);
    expect(f.dimension, QuotaDimension.rpd);
  });

  test('429 明确每分钟 → rpmLimited', () {
    final f = classify(429, '''
{"error":{"message":"Quota exceeded","details":[{"violations":[
{"quotaId":"GenerateRequestsPerMinutePerProjectPerModel"}]}]}}
''');
    expect(f.kind, FailureKind.rpmLimited);
    expect(f.dimension, QuotaDimension.rpm);
  });

  test('429 输入 token 每分钟 → tpmLimited', () {
    final f = classify(429, '''
{"error":{"message":"Quota exceeded","details":[{"violations":[
{"quotaId":"GenerateContentInputTokensPerModelPerMinute"}]}]}}
''');
    expect(f.kind, FailureKind.tpmLimited);
    expect(f.dimension, QuotaDimension.tpm);
  });

  test('429 只有 RESOURCE_EXHAUSTED → unknown429（不封到次日）', () {
    final f = classify(429, '{"error":{"status":"RESOURCE_EXHAUSTED"}}');
    expect(f.kind, FailureKind.unknown429);
  });

  test('429 limit=0 → quotaUnavailable', () {
    final f = classify(429, '''
{"error":{"message":"no quota","details":[{"violations":[{"limit":0}]}]}}
''');
    expect(f.kind, FailureKind.quotaUnavailable);
  });

  test('404 返回 HTML → endpointMisconfigured', () {
    final f = classify(404, '<!doctype html><html>not found</html>');
    expect(f.kind, FailureKind.endpointMisconfigured);
  });

  test('404 模型不存在 → modelUnavailable', () {
    final f = classify(404,
        '{"error":{"message":"models/gemini-9 does not exist for API version v1beta"}}');
    expect(f.kind, FailureKind.modelUnavailable);
  });

  test('403 模型权限 → modelAccessDenied；其他 403 → upstreamAccessError', () {
    expect(
      classify(403, '{"error":{"message":"You do not have access to model gemini-4-argon"}}')
          .kind,
      FailureKind.modelAccessDenied,
    );
    expect(
      classify(403, '{"error":{"message":"User location is not supported"}}').kind,
      FailureKind.upstreamAccessError,
    );
  });

  test('400 可修复参数 → repairableParam', () {
    final f = classify(400,
        '{"error":{"message":"temperature not supported","param":"temperature"}}');
    expect(f.kind, FailureKind.repairableParam);
    expect(f.param, 'temperature');
  });

  test('400 penalty 未启用 → repairableParam（合成组键）', () {
    final f = classify(400,
        '{"error":{"code":400,"message":"Penalty is not enabled for this model","status":"INVALID_ARGUMENT"}}');
    expect(f.kind, FailureKind.repairableParam);
    expect(f.param, 'penalty');
  });

  test('400 上下文过长 → invalidRequest(context_length_exceeded)', () {
    final f = classify(400,
        '{"error":{"message":"The input is too long: context length exceeded"}}');
    expect(f.kind, FailureKind.invalidRequest);
    expect(f.code, 'context_length_exceeded');
  });

  test('400 安全拦截 → blocked', () {
    final f = classify(400, '{"error":{"message":"Blocked by safety filters"}}');
    expect(f.kind, FailureKind.blocked);
  });

  test('5xx → transient', () {
    expect(classify(503, '{"error":{"message":"overloaded"}}').kind,
        FailureKind.transient);
  });

  test('Retry-After 秒数被解析', () {
    final f = classify(429, '{"error":{"message":"quota"}}',
        headers: {'retry-after': '42'});
    expect(f.retryAfterSeconds, 42);
  });

  test('无法识别的状态 → upstreamProtocolError', () {
    expect(classify(418, '').kind, FailureKind.upstreamProtocolError);
  });
}
