import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mysuperwall_sdk/src/services/offline_event_queue.dart';
import 'package:mysuperwall_sdk/src/services/pending_purchase_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storageKey = 'mysuperwall_offline_events_queue';
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Map<String, dynamic> event(String id) => {
    'eventId': id,
    'type': 'purchase_success',
    'userId': 'buyer',
    'appKey': 'app',
    'productId': 'pro',
  };

  test(
    'purchase is on disk before delivery and only explicit acknowledgements remove it',
    () async {
      final prefs = await SharedPreferences.getInstance();
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final events = body['events'] as List;
        expect(events.length, 2);
        expect(prefs.getString(storageKey), contains('purchase-first'));
        return http.Response(
          jsonEncode({
            'ok': true,
            'processed': 1,
            'invalid': 1,
            'acknowledgedEventIds': ['purchase-first'],
            'rejectedEventIds': ['purchase-second'],
          }),
          200,
        );
      });
      final queue = OfflineEventQueue(preferences: prefs, httpClient: client);
      addTearDown(queue.dispose);
      expect(await queue.enqueuePersisted(event('purchase-first')), isTrue);
      expect(await queue.enqueuePersisted(event('purchase-second')), isTrue);
      expect(requests, 0);
      queue.releaseDirectDelivery('purchase-first');
      queue.releaseDirectDelivery('purchase-second');
      await queue.flush(baseUrl: 'https://example.test/', appKey: 'app');
      final stored = jsonDecode(prefs.getString(storageKey)!) as List;
      expect(stored.length, 1);
      expect(stored.single['eventId'], 'purchase-second');
      expect(stored.single['_rejected'], isTrue);
      await queue.flush();
      expect(
        requests,
        1,
        reason: 'rejected rows are retained without starving other events',
      );
    },
  );

  test(
    'malformed 200 responses and network loss retain durable purchases across restart',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final client = MockClient((_) async => http.Response('{}', 200));
      final queue = OfflineEventQueue(preferences: prefs, httpClient: client);
      await queue.enqueuePersisted(event('purchase-retained'));
      queue.releaseDirectDelivery('purchase-retained');
      await queue.flush(baseUrl: 'https://example.test/', appKey: 'app');
      expect(prefs.getString(storageKey), contains('purchase-retained'));
      queue.dispose();
      final restarted = OfflineEventQueue(
        preferences: prefs,
        httpClient: MockClient((_) async {
          throw http.ClientException('offline');
        }),
      );
      addTearDown(restarted.dispose);
      await restarted.flush(baseUrl: 'https://example.test/', appKey: 'app');
      expect(prefs.getString(storageKey), contains('purchase-retained'));
    },
  );

  test(
    'legacy mixed/partial acknowledgements do not erase the purchase',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final queue = OfflineEventQueue(
        preferences: prefs,
        httpClient: MockClient(
          (_) async =>
              http.Response('{"ok":true,"processed":0,"invalid":1}', 200),
        ),
      );
      addTearDown(queue.dispose);
      await queue.enqueuePersisted(event('legacy-partial'));
      queue.releaseDirectDelivery('legacy-partial');
      await queue.flush(baseUrl: 'https://example.test/', appKey: 'app');
      expect(prefs.getString(storageKey), contains('legacy-partial'));
    },
  );

  test(
    'deferred completion requires a real attempt, not restored ownership or another user',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final store = PendingPurchaseStore(prefs);
      var writes = 0;
      Future<bool> complete(String scope, DateTime date) => store.complete(
        scope: scope,
        productId: 'pro',
        purchasedAt: date,
        transactionEventId: 'transaction-deferred',
        onlyIfPending: true,
        record: (_, __) async {
          writes++;
          return true;
        },
      );
      expect(await complete('user-a', DateTime.now()), isFalse);
      await store.begin('user-a', 'pro:weekly', {'paywallId': 'original-wall'});
      expect(await complete('user-b', DateTime.now()), isFalse);
      expect(
        await complete(
          'user-a',
          DateTime.now().subtract(const Duration(days: 1)),
        ),
        isFalse,
      );
      expect(await complete('user-a', DateTime.now()), isTrue);
      expect(await complete('user-a', DateTime.now()), isFalse);
      expect(writes, 1);
    },
  );

  test(
    'callback/listener races count once and persistence failure leaves recovery pending',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final store = PendingPurchaseStore(prefs);
      await store.begin('scope', 'pro', {'paywallId': 'original-wall'});
      var writes = 0;
      var canPersist = false;
      Future<bool> complete() => store.complete(
        scope: 'scope',
        productId: 'pro',
        purchasedAt: DateTime.now(),
        transactionEventId: 'transaction-race',
        onlyIfPending: true,
        record: (_, context) async {
          expect(context?['paywallId'], 'original-wall');
          if (!canPersist) return false;
          writes++;
          return true;
        },
      );
      expect(await complete(), isFalse);
      canPersist = true;
      final results = await Future.wait([complete(), complete()]);
      expect(results.where((value) => value).length, 1);
      expect(writes, 1);
    },
  );

  group('a wrong device clock does not lose a purchase', () {
    late PendingPurchaseStore store;
    late List<String> recorded;

    setUp(() async {
      store = PendingPurchaseStore(await SharedPreferences.getInstance());
      recorded = [];
    });

    Future<bool> complete(
      DateTime purchasedAt, {
      String id = 'transaction-a',
      bool onlyIfPending = false,
    }) => store.complete(
      scope: 'scope',
      productId: 'pro:yearly',
      purchasedAt: purchasedAt,
      transactionEventId: id,
      onlyIfPending: onlyIfPending,
      record: (eventId, _) async {
        recorded.add(eventId);
        return true;
      },
    );

    // The store reports true time, so a clock ahead makes it look earlier.
    Future<void> expectRecorded(Duration deviceAhead, {bool update = false}) async {
      await store.begin('scope', 'pro:yearly', {});
      final storeTime = DateTime.now().toUtc().subtract(deviceAhead);
      expect(await complete(storeTime, onlyIfPending: update), isTrue);
      expect(recorded, ['transaction-a']);
    }

    test('2 minutes ahead', () => expectRecorded(const Duration(minutes: 2)));
    test('3 days ahead', () => expectRecorded(const Duration(days: 3)));
    test('10 minutes behind', () => expectRecorded(const Duration(minutes: -10)));
    test('3 days behind', () => expectRecorded(const Duration(days: -3)));
    test(
      'a deferred update with 2 minutes of skew',
      () => expectRecorded(const Duration(minutes: 2), update: true),
    );

    test('old ownership in an update is still not a new purchase', () async {
      await store.begin('scope', 'pro:yearly', {});
      final old = DateTime.now().toUtc().subtract(const Duration(days: 2));
      expect(await complete(old, onlyIfPending: true), isFalse);
      expect(recorded, isEmpty);
    });

    test('a direct result without an attempt must still be recent', () async {
      final old = DateTime.now().toUtc().subtract(const Duration(days: 2));
      expect(await complete(old), isFalse);
      expect(await complete(DateTime.now().toUtc()), isTrue);
    });

    test('update and result with different IDs count one checkout', () async {
      await store.begin('scope', 'pro:yearly', {});
      final now = DateTime.now().toUtc();
      expect(await complete(now, id: 'from-update', onlyIfPending: true), isTrue);
      expect(await complete(now, id: 'from-result'), isFalse);
      expect(recorded, ['from-update']);
    });

    test('a later purchase with its own attempt still counts', () async {
      await store.begin('scope', 'pro:yearly', {});
      final now = DateTime.now().toUtc();
      expect(await complete(now, id: 'first'), isTrue);
      await store.begin('scope', 'pro:yearly', {});
      expect(await complete(now, id: 'second'), isTrue);
      expect(recorded, ['first', 'second']);
    });
  });

  test('a damaged journal does not stop purchase tracking', () async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'mysuperwall_pending_purchases_${base64Url.encode(utf8.encode('scope'))}';
    await prefs.setString(key, '{broken');
    final store = PendingPurchaseStore(prefs);
    await store.begin('scope', 'pro', {});
    expect(
      await store.complete(
        scope: 'scope',
        productId: 'pro',
        purchasedAt: DateTime.now().toUtc(),
        transactionEventId: 'after-damage',
        onlyIfPending: true,
        record: (_, __) async => true,
      ),
      isTrue,
    );
  });

  group('stored queue', () {
    OfflineEventQueue open(SharedPreferences prefs) => OfflineEventQueue(
      preferences: prefs,
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );
    List stored(SharedPreferences prefs) =>
        jsonDecode(prefs.getString(storageKey)!) as List;

    test('stays bounded and never drops a purchase', () async {
      final prefs = await SharedPreferences.getInstance();
      final queue = open(prefs);
      addTearDown(queue.dispose);
      await queue.enqueuePersisted(event('purchase-kept'));
      queue.releaseDirectDelivery('purchase-kept');
      for (var i = 0; i < 620; i++) {
        queue.enqueue({'eventId': 'shown-$i', 'type': 'paywall_shown', 'userId': 'buyer'});
      }
      await queue.acknowledge('not-queued');
      final rows = stored(prefs);
      expect(rows.length, 500);
      expect(rows.first['eventId'], 'purchase-kept');
      expect(rows.last['eventId'], 'shown-619');
    });

    test('a rejected purchase is retried after a restart, other events are not', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, jsonEncode([
        {...event('purchase-rejected'), '_rejected': true, '_queueScope': 'x'},
        {'eventId': 'shown-rejected', 'type': 'paywall_shown', '_rejected': true, '_queueScope': 'x'},
      ]));
      final queue = open(prefs);
      addTearDown(queue.dispose);
      await queue.acknowledge('not-queued');
      final rows = stored(prefs);
      expect(rows.first['_rejected'], isNull);
      expect(rows.last['_rejected'], isTrue);
    });
  });
}
