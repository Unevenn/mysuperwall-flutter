import 'package:flutter_test/flutter_test.dart';
import 'package:mysuperwall_sdk/src/models/paywall_manifest.dart';
import 'package:mysuperwall_sdk/src/services/lifecycle_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

ManifestTrigger trigger({Map<String, dynamic> schedule = const {}, Map<String, dynamic> limit = const {}}) =>
    ManifestTrigger.fromJson({
      'id': 't',
      'key': 'mysuperwall.session',
      'schedule': schedule,
      'displayLimit': limit,
    });

void main() {
  final now = DateTime.utc(2026, 11, 7, 12);
  late LifecycleGate gate;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gate = LifecycleGate(await SharedPreferences.getInstance(), 'gate');
  });

  String? reason(ManifestTrigger t, {int sessions = 5, bool premium = false, DateTime? at}) =>
      gate.blockReason(t, sessions: sessions, premium: premium, now: at ?? now);

  test('a manifest without schedule fields never blocks', () {
    expect(reason(ManifestTrigger.fromJson({'id': 't', 'key': 'k'}), sessions: 0), isNull);
  });

  test('waits for the configured open', () {
    final t = trigger(schedule: {'fromOpen': 2});
    expect(reason(t, sessions: 1), 'schedule_not_reached');
    expect(reason(t, sessions: 2), isNull);
  });

  test('subscribers are skipped only when asked', () {
    expect(reason(trigger(limit: {'hideForPurchasers': true}), premium: true), 'purchased');
    expect(reason(trigger(), premium: true), isNull);
  });

  test('interval and total limit stop requests after a show', () async {
    final t = trigger(limit: {'minIntervalHours': 6, 'maxPerUser': 2});
    await gate.recordShown(t.key, now);
    expect(reason(t, at: now.add(const Duration(hours: 5))), 'min_interval');
    expect(reason(t, at: now.add(const Duration(hours: 6))), isNull);
    await gate.recordShown(t.key, now.add(const Duration(hours: 6)));
    expect(reason(t, at: now.add(const Duration(days: 30))), 'max_per_user');
  });

  test('period cap and dismissals', () async {
    final t = trigger(limit: {'maxPerPeriod': 1, 'period': 'week', 'stopAfterDismissals': 2});
    await gate.recordShown(t.key, now);
    expect(reason(t, at: now.add(const Duration(days: 6))), 'max_per_period');
    expect(reason(t, at: now.add(const Duration(days: 8))), isNull);
    await gate.recordDismissed(t.key);
    await gate.recordDismissed(t.key);
    expect(reason(t, at: now.add(const Duration(days: 8))), 'dismissals');
  });

  test('a server rejection backs off until the given time or for a day', () async {
    final t = trigger();
    await gate.recordRejected(t.key, now, until: now.add(const Duration(hours: 2)));
    expect(reason(t, at: now.add(const Duration(hours: 1))), 'server_rejected');
    expect(reason(t, at: now.add(const Duration(hours: 2))), isNull);
    await gate.recordRejected(t.key, now);
    expect(reason(t, at: now.add(const Duration(hours: 23))), 'server_rejected');
  });

  test('counts survive a restart', () async {
    final t = trigger(limit: {'maxPerUser': 1});
    await gate.recordShown(t.key, now);
    final reopened = LifecycleGate(await SharedPreferences.getInstance(), 'gate');
    expect(reopened.blockReason(t, sessions: 5, premium: false, now: now), 'max_per_user');
  });

  test('delay counts from when the app became ready', () {
    final t = trigger(schedule: {'delaySeconds': 5});
    expect(gate.remainingDelay(t, now, now.add(const Duration(seconds: 3))), const Duration(seconds: 2));
    expect(gate.remainingDelay(t, now, now.add(const Duration(seconds: 6))), Duration.zero);
  });
}
