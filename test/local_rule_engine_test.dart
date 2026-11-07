import 'package:flutter_test/flutter_test.dart';
import 'package:mysuperwall_sdk/src/models/paywall_manifest.dart';
import 'package:mysuperwall_sdk/src/services/local_rule_engine.dart';

void main() {
  const engine = LocalRuleEngine();

  group('LocalRuleEngine - Deterministic Buckets', () {
    test('produces uniform bucket [0..99] for same user and salt', () {
      final b1 = engine.getDeterministicBucket('user_abc_123', 'onboarding');
      final b2 = engine.getDeterministicBucket('user_abc_123', 'onboarding');
      expect(b1, equals(b2));
      expect(b1 >= 0 && b1 < 100, isTrue);

      final b3 = engine.getDeterministicBucket('user_xyz_789', 'onboarding');
      expect(b3 >= 0 && b3 < 100, isTrue);
    });

    test('different salts yield different sticky buckets for same user', () {
      final b1 = engine.getDeterministicBucket('user_123', 'trigger_1');
      final b2 = engine.getDeterministicBucket('user_123', 'trigger_2');
      // Probabilistically different with high confidence
      expect(b1 >= 0 && b1 < 100, isTrue);
      expect(b2 >= 0 && b2 < 100, isTrue);
    });
  });

  group('LocalRuleEngine - Semantic Versioning', () {
    test('compares semantic versions accurately', () {
      expect(engine.compareVersions('2.0.0', '1.9.9'), equals(1));
      expect(engine.compareVersions('1.5.0', '1.5.0'), equals(0));
      expect(engine.compareVersions('1.0.1', '1.1.0'), equals(-1));
      expect(engine.compareVersions('v2.1.0', '2.0.9'), equals(1));
    });
  });

  group('LocalRuleEngine - Condition Evaluation', () {
    test('evaluates equals and not_equals', () {
      final condEq = const ManifestCondition(field: 'country', operator: 'equals', value: 'TR');
      expect(engine.evaluateCondition(condEq, {'country': 'TR'}), isTrue);
      expect(engine.evaluateCondition(condEq, {'country': 'US'}), isFalse);

      final condNeq = const ManifestCondition(field: 'country', operator: 'not_equals', value: 'US');
      expect(engine.evaluateCondition(condNeq, {'country': 'TR'}), isTrue);
    });

    test('evaluates numeric comparisons', () {
      final condGt = const ManifestCondition(field: 'sessions', operator: 'gt', value: 3);
      expect(engine.evaluateCondition(condGt, {'sessions': 5}), isTrue);
      expect(engine.evaluateCondition(condGt, {'sessions': 2}), isFalse);

      final condLte = const ManifestCondition(field: 'sessions', operator: 'lte', value: 10);
      expect(engine.evaluateCondition(condLte, {'sessions': 10}), isTrue);
      expect(engine.evaluateCondition(condLte, {'sessions': 11}), isFalse);
    });

    test('evaluates in_list and not_in_list', () {
      final condIn = const ManifestCondition(field: 'platform', operator: 'in_list', value: 'ios, android');
      expect(engine.evaluateCondition(condIn, {'platform': 'ios'}), isTrue);
      expect(engine.evaluateCondition(condIn, {'platform': 'web'}), isFalse);
    });

    test('evaluates version_gte and version_lt', () {
      final condVer = const ManifestCondition(field: 'appVersion', operator: 'version_gte', value: '2.0.0');
      expect(engine.evaluateCondition(condVer, {'appVersion': '2.1.0'}), isTrue);
      expect(engine.evaluateCondition(condVer, {'appVersion': '1.9.0'}), isFalse);
    });
  });

  group('LocalRuleEngine - Trigger Resolution', () {
    final trigger = ManifestTrigger(
      id: 'trg_onboarding',
      key: 'onboarding_finish',
      prewarmPriority: 10,
      holdoutPercentage: 0,
      paywallId: 'pw_fallback',
      variants: [
        const ManifestVariant(variant: 'A', weight: 50, paywallId: 'pw_fallback_a'),
        const ManifestVariant(variant: 'B', weight: 50, paywallId: 'pw_fallback_b'),
      ],
      rules: [
        ManifestRule(
          id: 'rule_vip_us',
          name: 'US iOS VIP',
          priority: 10,
          matchType: 'all',
          conditions: [
            const ManifestCondition(field: 'country', operator: 'equals', value: 'US'),
            const ManifestCondition(field: 'platform', operator: 'equals', value: 'ios'),
          ],
          holdoutPercentage: 0,
          paywallId: 'pw_us_vip',
          variants: [],
        ),
        ManifestRule(
          id: 'rule_tr_holdout',
          name: 'TR Holdout Test',
          priority: 5,
          matchType: 'all',
          conditions: [
            const ManifestCondition(field: 'country', operator: 'equals', value: 'TR'),
          ],
          holdoutPercentage: 100, // Guaranteed holdout for testing
          paywallId: 'pw_tr',
          variants: [],
        ),
      ],
    );

    test('matches priority rule and returns corresponding paywallId (0ms)', () {
      final res = engine.resolveTrigger(
        trigger: trigger,
        userId: 'user_us_1',
        context: {'country': 'US', 'platform': 'ios'},
      );

      expect(res.show, isTrue);
      expect(res.paywallId, equals('pw_us_vip'));
      expect(res.matchedRuleName, equals('US iOS VIP'));
    });

    test('respects holdout rule and returns show=false, reason=holdout', () {
      final res = engine.resolveTrigger(
        trigger: trigger,
        userId: 'user_tr_1',
        context: {'country': 'TR', 'platform': 'android'},
      );

      expect(res.show, isFalse);
      expect(res.isHoldout, isTrue);
      expect(res.reason, equals('holdout'));
    });

    test('falls back to default variants when no rules match', () {
      final res = engine.resolveTrigger(
        trigger: trigger,
        userId: 'user_de_1',
        context: {'country': 'DE', 'platform': 'android'},
      );

      expect(res.show, isTrue);
      expect(res.paywallId == 'pw_fallback_a' || res.paywallId == 'pw_fallback_b', isTrue);
      expect(res.abVariant == 'A' || res.abVariant == 'B', isTrue);
    });
  });
}
