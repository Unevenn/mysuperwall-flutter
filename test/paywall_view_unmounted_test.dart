import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mysuperwall_sdk/src/models/paywall_data.dart';
import 'package:mysuperwall_sdk/src/ui/paywall_view.dart';

void main() {
  testWidgets('showing on a closed screen does nothing', (tester) async {
    late BuildContext closed;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            closed = context;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    expect(closed.mounted, isFalse);

    await PaywallView.show(
      closed,
      paywall: PaywallData.fromJson(const {'id': 'wall', 'html': '<html></html>'}),
    );

    expect(tester.takeException(), isNull);
    expect(PaywallView.isShowing, isFalse);
  });
}
