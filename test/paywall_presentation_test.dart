import 'package:flutter_test/flutter_test.dart';
import 'package:mysuperwall_sdk/src/models/paywall_presentation.dart';
import 'package:mysuperwall_sdk/src/ui/paywall_host.dart';
import 'package:mysuperwall_sdk/src/ui/paywall_session.dart';

void main() {
  group('PaywallPresentationConfig.fromContentJson', () {
    test('parses slide up style aliases', () {
      for (final style in [
        'slideUp',
        'slide_up',
        'bottom_up',
        'bottom-to-top',
        'from_bottom',
      ]) {
        final presentation = PaywallPresentationConfig.fromContentJson({
          'presentation': {'style': style},
        });

        expect(presentation.style, PaywallPresentationStyle.slideUp);
      }
    });

    test('parses system and unknown styles as system', () {
      final system = PaywallPresentationConfig.fromContentJson({
        'presentation': {'style': 'system'},
      });
      final unknown = PaywallPresentationConfig.fromContentJson({
        'presentation': {'style': 'not_a_real_transition'},
      });

      expect(system.style, PaywallPresentationStyle.system);
      expect(unknown.style, PaywallPresentationStyle.system);
    });
  });

  group('preparedPaywallBeginFractionalOffset', () {
    test('uses slide up offset for system style', () {
      const presentation = PaywallPresentationConfig(
        style: PaywallPresentationStyle.system,
      );

      expect(preparedPaywallBeginFractionalOffset(presentation),
          const Offset(0, 1));
    });

    test('keeps none style without movement', () {
      const presentation = PaywallPresentationConfig(
        style: PaywallPresentationStyle.none,
      );

      expect(preparedPaywallBeginFractionalOffset(presentation), Offset.zero);
    });
  });

  group('PreparedPaywallController.buildHtml', () {
    test('injects the paint-ready bridge before body close', () {
      final html = PreparedPaywallController.buildHtml(
        'https://mysuperwall.com/',
        '<html><head></head><body><main>Paywall</main></body></html>',
      );

      expect(html, contains('<base href="https://mysuperwall.com/">'));
      expect(html, contains('MySuperWallReady.postMessage'));
      expect(
        html.indexOf('MySuperWallReady.postMessage'),
        lessThan(html.indexOf('</body>')),
      );
    });
  });
}
