[![MySuperWall — Make it beautiful. Make it live.](https://mysuperwall.com/assets/sdk/flutter-readme-hero-v1.png)](https://mysuperwall.com)

# Beautiful paywalls. Delivered in Flutter.

Design in MySuperWall. Publish remotely. Show the right paywall in your app — with **your products, your pricing, and your existing billing integration**.

[![pub package](https://img.shields.io/pub/v/mysuperwall_sdk.svg?color=8B5CF6&label=pub.dev)](https://pub.dev/packages/mysuperwall_sdk)
[![Flutter](https://img.shields.io/badge/Flutter-3.35%2B-02569B?logo=flutter)](https://flutter.dev)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20Android-5D536B)](https://pub.dev/packages/mysuperwall_sdk)
[![License: MIT](https://img.shields.io/badge/license-MIT-8B5CF6)](https://pub.dev/packages/mysuperwall_sdk/license)

**[Open dashboard →](https://mysuperwall.com)** · **[Documentation](https://mysuperwall.com/docs/)** · **[Example app](https://pub.dev/packages/mysuperwall_sdk/example)** · **[Report an issue](https://github.com/Unevenn/mysuperwall-flutter/issues)**

---

## Design. Publish. Learn.

| Make it yours | Show it with purpose | Keep improving |
| :--- | :--- | :--- |
| **AI-assisted design** — create and refine paywalls with your coding agent connected to MySuperWall. | **Audience targeting** — configure rules and variants in the dashboard, then present by trigger key. | **A/B experiments** — compare SDK-reported displays and purchase outcomes in the dashboard. |
| **Remote publishing** — update published paywall designs and content without a new app release. | **Localized experiences** — select paywall language independently from the audience’s country. | **Recovery flows** — connect a second paywall with bounded chains, cooldowns and repeat protection. |

### Made to fit your app

- **Keep your billing.** Connect RevenueCat, `in_app_purchase`, or your own store integration through purchase and restore callbacks.
- **Prepare before the moment.** Cache manifests, prefetch paywalls and keep views ready with `MySuperWallHost`.
- **Handle connectivity gracefully.** Use available cached paywalls; the default transient-network fallback lets your app continue when a paywall cannot be loaded.
- **Use the dependencies you already have.** Compatible `package_info_plus` and `device_info_plus` versions are accepted across multiple major releases.

> Dashboard features depend on your MySuperWall account plan. Store billing and entitlement decisions remain in your application.

---

## From dashboard to your first paywall

1. **Create** an app, add your store product IDs and design a paywall.
2. **Publish** it and connect it to a trigger such as `onboarding_finish`.
3. **Integrate** the SDK using your app key, then present that trigger.

### 1. Install

```yaml
dependencies:
  mysuperwall_sdk: ^1.2.1
```

Requires **Flutter 3.35+ / Dart 3.9+**. Supports **iOS and Android**.

### 2. Initialize

```dart
import 'package:flutter/material.dart';
import 'package:mysuperwall_sdk/mysuperwall_sdk.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await MySuperWallClient.initialize(
    appKey: 'YOUR_APP_KEY', // Dashboard → your app → Settings
    locale: 'en', // your app's language, set once here
  );
  runApp(const MyApp());
}
```

Pass the app language to `initialize`, not before each presentation: a later `setLocale` with a different value (for example `tr` while the device default is `tr-tr`) clears the cached manifest and the prepared paywall.

Add the host to your existing `MaterialApp` or `GetMaterialApp` builder. Preserve any builder your app already uses.

```dart
builder: (context, child) => MySuperWallHost(
  child: child ?? const SizedBox.shrink(),
),
```

### 3. Prepare once at startup

When your store prices are available (for example after RevenueCat returns the current offering), push them once and warm the paywall you show most often. `MySuperWallHost` keeps one prepared paywall by default, so the next `handleTrigger` for that trigger opens instantly.

```dart
final client = MySuperWallClient.instance;
await client.setProductPrices(localizedPrices); // from your billing provider
await client.setPreparedPaywallPreferences(
  preferredTriggerKeys: const ['premium'],
  warmPool: false,
);
await client.prefetchAllActivePaywalls();
await client.warmPreparedPaywalls();
```

Do this at startup and again only when prices or the language change. Calling `setProductPrices` or `setLocale` with new values before every presentation discards the prepared paywall and rebuilds it, which makes every opening slow.

### 4. Present

```dart
final result = await MySuperWallClient.instance.handleTrigger(
  context,
  triggerKey: 'onboarding_finish',
  onPurchase: (productId) async {
    // Connect your real purchase handler here.
    // Report success only after your billing provider confirms completion.
  },
  onRestore: () {
    // Restore purchases through your existing billing integration.
  },
);

if (!result.show) {
  // No matching paywall, holdout, or an unavailable delivery.
  // Continue with your application's normal flow.
}
```

After your billing provider confirms a completed purchase:

```dart
await MySuperWallClient.instance.trackPurchaseSuccess(
  productId: confirmedProductId,
);
```

**A button tap is not a successful purchase.** The SDK presents the paywall and exposes callbacks; your billing provider completes the transaction.

---

## The details, when you need them

<details>
<summary><strong>Localized product prices &amp; introductory offers</strong></summary>

Read localized prices from your store integration and pass them by product ID once they are loaded (see *Prepare once at startup*), not before every presentation. The strings below are illustrative; use actual store values in production.

```dart
await MySuperWallClient.instance.setProductPrices({
  'weekly_sku': '\$6.99',
  'monthly_sku': '\$19.99',
});
```

For introductory offers and per-period text:

```dart
await MySuperWallClient.instance.setStructuredProductData({
  'weekly_sku': const MySuperWallProductDataEntry(
    displayPrice: '\$6.99',
    pricePerWeekText: '\$6.99',
    introDisplayPrice: '\$1.99',
    introEligible: true,
    introUsed: false,
  ),
});
```

Pass eligibility from your billing provider. Price placeholders use the introductory price when eligible and the regular price otherwise.

</details>

<details>
<summary><strong>Identity, language &amp; audience country</strong></summary>

```dart
final client = MySuperWallClient.instance;
client.setUserId('YOUR_AUTHENTICATED_USER_ID');
client.setLocale('tr');
client.setCountry('TR');
client.setSubscriptionStatus(hasActiveEntitlement);
```

An anonymous user ID is generated when omitted during initialization. Language and country are separate settings. Regional languages fall back to the base translation on compatible backends. Identity and locale changes invalidate the active manifest scope and cancel pending default recovery.

</details>

<details>
<summary><strong>Recovery paywalls &amp; restore completion</strong></summary>

`handleTrigger` runs configured follow-up rules with once-per-session, cooldown, chain-depth and repeat protection. A legacy dismiss second screen uses the current manifest and retries synchronization when needed; offline recovery requires a cached target.

Pass real entitlement state through `setSubscriptionStatus(bool)` for rules using `skipIfPremium`. After a confirmed restore:

```dart
MySuperWallClient.instance.trackRestoreSuccess(
  paywallId: displayedPaywallId,
);
```

Purchase success rules follow host-confirmed completion calls. Existing `setAutomationActionHandler` integrations take precedence over the default runner, preventing double presentation.

</details>

<details>
<summary><strong>Caching, prefetching &amp; lifecycle triggers</strong></summary>

The SDK caches manifests on disk and evaluates available rules locally. Use prefetching and `MySuperWallHost` to prepare views before presentation. An initial successful synchronization is needed before cached delivery is available.

Built-in lifecycle triggers include:

- `mysuperwall.install`, `mysuperwall.update`, `mysuperwall.session`
- `mysuperwall.session_3/5/10/20/50`
- `mysuperwall.day_1/3/7/14/30`

Fetching or preparing a paywall is separate from displaying it. Analytics reflects SDK-reported activity; it is not independent proof of screen visibility or a store transaction.

</details>

<details>
<summary><strong>Dependency compatibility</strong></summary>

| Dependency | Accepted range |
| :--- | :--- |
| `package_info_plus` | `>=9.0.0 <11.0.0` |
| `device_info_plus` | `>=11.5.0 <14.0.0` |

Your app can retain compatible constraints such as `^9.0.0` and `^11.5.0`. Pub selects versions satisfying both your app and the SDK. Other dependency and platform/toolchain requirements also apply. Future major versions require API review before extending the upper bound.

</details>

<details>
<summary><strong>Advanced: optional store-proof verification</strong></summary>

### Optional store-proof verification

Your billing integration still handles purchase, acknowledgment/consumption and
entitlements. After it reports a completed purchase, pass the store-issued proof:

```dart
Future<void> reportCompletedApplePurchase({
  required String productId,
  required String transactionId,
}) async {
  await MySuperWallClient.instance.trackPurchaseSuccess(
    productId: productId,
    proof: StorePurchaseProof.apple(transactionId: transactionId),
    onVerification: (result) {
      // A transaction proof is not authorization to grant a user entitlement.
      // result.retryable identifies transport/server/rate-limit failures.
    },
  );
}
```

Use `StorePurchaseProof.googleProduct(purchaseToken: token)` for Google one-time
products or `StorePurchaseProof.googleSubscription(purchaseToken: token)` for
subscriptions. Supply the **purchase token**, not the Google order ID or full
JSON receipt. Apple needs the transaction ID, not its base64 app receipt.
Extract these values from your own billing provider's completed-purchase result;
the SDK does not depend on RevenueCat or any particular billing package.

Existing `trackPurchaseSuccess` calls remain compatible and send unverified
analytics when no proof is supplied. `onVerification` is optional and receives
verification separately from the billing outcome. The original `Future<void>`
return type is preserved. A verification failure never marks a successful store
payment as a billing failure.

To retry only verification without another reported analytics event:

```dart
Future<PurchaseVerificationResult> retryAppleVerification({
  required String productId,
  required String transactionId,
}) => MySuperWallClient.instance.verifyPurchase(
  productId: productId,
  proof: StorePurchaseProof.apple(transactionId: transactionId),
);
```

Initialize with the dashboard `appKey`; verification requires an explicit key.
Configure the matching app's encrypted Apple/Google store connection first.
Requests use the existing HTTP client and timeout. Network/timeouts/server errors
get at most three attempts with bounded backoff; 4xx responses (including 429)
are returned without an immediate retry. No proof is persisted or logged by the
verification service. There is no durable offline retry queue; retry from the
billing integration when connectivity returns. Never put proofs in analytics
metadata or logs.

`PurchaseVerificationResult` includes `verified`, `duplicate`, `environment`,
`amountUsd`, `reason`, `statusCode` and `retryable`. Sandbox is determined by the
store. A null amount is unknown, not zero; Google amounts remain unknown when the
purchase API does not provide an actual charge. Do not combine direct-store and
RevenueCat totals for the same transactions. Backend contract:
`backend/docs/purchase-verification-api.md` in the MySuperWall backend repository.


</details>

---

## Build something worth subscribing to.

**[Create your MySuperWall account →](https://mysuperwall.com)**

[Integration documentation](https://mysuperwall.com/docs/) · [Changelog](https://pub.dev/packages/mysuperwall_sdk/changelog) · [GitHub](https://github.com/Unevenn/mysuperwall-flutter)

Illustrated paywalls in the header demonstrate visual possibilities, rather than bundled templates. Licensed under [MIT](https://pub.dev/packages/mysuperwall_sdk/license).

### SDK log level

SDK logging defaults to `MySuperWallLogLevel.warning` (warnings and errors),
including in release builds. Configure it during initialization:

```dart
await MySuperWallClient.initialize(
  appKey: 'YOUR_APP_KEY',
  logLevel: MySuperWallLogLevel.warning,
);
```

Use `all` for every SDK message, `error` for errors only, or `none` to disable
SDK logging. Change it at runtime with
`MySuperWallClient.setLogLevel(MySuperWallLogLevel.none)`.
This setting does not change your application's own logs.

### Paywall lifecycle

Read the current state of a trigger or listen for changes:

```dart
final sdk = MySuperWallClient.instance;
final state = sdk.paywallStateFor('location');

void onPaywallStatesChanged() {
  final state = sdk.paywallStateFor('location');
  // Update your application's controller using this state.
}

sdk.paywallStates.addListener(onPaywallStatesChanged);
// Remove the listener when your application's controller is disposed:
sdk.paywallStates.removeListener(onPaywallStatesChanged);
```

States are `idle`, `loading`, `ready`, `presenting`, `visible`, `dismissed`, and
`failed`. They describe each trigger, including background preparation.
`paywall_shown` is emitted at most once per presentation, after the opening
transition finishes and the WebView reports paint readiness, while the paywall
is active and the app is in the foreground. A readiness timeout alone does not
count as an impression. This does not delay the opening animation.
