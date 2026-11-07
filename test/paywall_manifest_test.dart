import 'package:flutter_test/flutter_test.dart';
import 'package:mysuperwall_sdk/src/models/paywall_manifest.dart';

void main() {
  group('PaywallManifest - JSON Serialization & Conversion', () {
    test('serializes and deserializes manifest cleanly', () {
      final json = {
        'hash': 'a1b2c3d4e5f6',
        'appId': 'app_test_123',
        'triggers': [
          {
            'id': 'trg_1',
            'key': 'feature_locked',
            'prewarmPriority': 5,
            'holdoutPercentage': 10,
            'paywallId': 'pw_1',
            'variants': [
              {'variant': 'A', 'weight': 60, 'paywallId': 'pw_1'},
              {'variant': 'B', 'weight': 40, 'paywallId': 'pw_2'}
            ],
            'rules': [
              {
                'id': 'rule_1',
                'name': 'VIP Rule',
                'priority': 1,
                'matchType': 'all',
                'conditions': [
                  {'field': 'isPro', 'operator': 'equals', 'value': false}
                ],
                'holdoutPercentage': 0,
                'paywallId': 'pw_1',
                'variants': []
              }
            ],
            'dismissAction': {
              'type': 'follow_up_paywall',
              'followUpPaywallId': 'pw_discount'
            }
          }
        ],
        'paywalls': {
          'pw_1': {
            'id': 'pw_1',
            'name': 'Premium Paywall',
            'templateKey': 'slide_up',
            'html': '<html><body><h1>Unlock All</h1></body></html>',
            'contentJson': {'headline': 'Unlock All Features'},
            'productIds': ['com.app.annual'],
            'products': [
              {'productId': 'com.app.annual', 'variableName': 'yearly_sub'}
            ]
          }
        }
      };

      final manifest = PaywallManifest.fromJson(json);
      expect(manifest.hash, equals('a1b2c3d4e5f6'));
      expect(manifest.appId, equals('app_test_123'));
      expect(manifest.triggers.length, equals(1));
      expect(manifest.paywalls.length, equals(1));

      final trigger = manifest.findTrigger('feature_locked');
      expect(trigger, isNotNull);
      expect(trigger!.key, equals('feature_locked'));
      expect(trigger.rules.length, equals(1));
      expect(trigger.dismissFollowUpPaywallId, equals('pw_discount'));

      final paywall = manifest.paywalls['pw_1'];
      expect(paywall, isNotNull);
      expect(paywall!.name, equals('Premium Paywall'));

      // Convert to PaywallResult
      final result = paywall.toPaywallResult(
        triggerKey: 'feature_locked',
        appKey: 'test_app_key',
        abVariant: 'A',
      );
      expect(result.show, isTrue);
      expect(result.paywall, isNotNull);
      expect(result.paywall!.id, equals('pw_1'));
      expect(result.paywall!.appKey, equals('test_app_key'));
      expect(result.paywall!.abVariant, equals('A'));
      expect(result.paywall!.html, contains('Unlock All'));
    });
  });
}
