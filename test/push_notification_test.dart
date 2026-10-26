import 'package:flutter_test/flutter_test.dart';
import 'package:mysuperwall_sdk/mysuperwall_sdk.dart';

void main() {
  test('recognises MySuperWall notification payloads', () {
    expect(
      MySuperWallClient.isMySuperWallNotification({'mysuperwall': '1', 'jobId': 'a'}),
      isTrue,
    );
    expect(MySuperWallClient.isMySuperWallNotification({'other': '1'}), isFalse);
    expect(MySuperWallClient.isMySuperWallNotification({}), isFalse);
  });
}
