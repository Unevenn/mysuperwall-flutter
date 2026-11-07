## 1.5.0 — 2026-11-07

- Do not open a paywall on a screen that closed while it was being prepared. This
  threw an error the app could not catch.
- A wrong device clock no longer loses a purchase: direct billing results are
  accepted whatever the clock says, and updates allow 12 hours of difference.
  One checkout reported with two transaction IDs counts once. A damaged purchase
  journal starts over instead of stopping tracking. The offline queue is limited
  to 500 events and never drops purchases; rejected purchases retry at launch.
- Stop renewing prepared paywall decisions on the 15-second host tick. A prepared
  paywall now asks the server when it is about to be shown, once its 30-second
  decision has expired, so idle apps make no renewal requests.
- Decide lifecycle triggers on the device: the panel's start, wait and repeat
  settings arrive in the manifest, and the server is asked only when a paywall
  can actually be shown. The periodic host tick no longer fetches the manifest
  (at most once per 10 minutes), a declined trigger is not requested again on
  every tick, and `lifecycle_status` diagnostics are limited to configured,
  eligible triggers plus one daily activity signal.
- Persist purchase events before delivery, retain them until explicit server
  acknowledgement, and replay at initialization/foreground. Preserve original
  occurrence time and deduplicate confirmed purchases by store transaction ID.
- Add `beginPurchaseTracking`, `completePurchaseTracking`, and
  `cancelPurchaseTracking` for billing SDK update listeners and pending-payment
  recovery. Persist attempt context across restarts; do not infer conversions
  from restored ownership. Purchase callbacks complete after local persistence.
- Keep invalid batch events locally for diagnosis without blocking valid events;
  malformed/partial responses never discard unacknowledged purchases.
- Reuse server-authorized delivery decisions for up to 30 seconds, varying by
  all audience inputs. Renew warm decisions in the foreground without waiting
  on a delivery request for every tap. Legacy servers retain live delivery.
- Keep history-based audiences, display limits, lifecycle/follow-up delivery and
  test users on live decisions; invalidate reuse on identity, locale, country,
  entitlement, product or manifest changes. Leases are never persisted to disk.
- Reuse identical prepared content with targeting metadata. Preserve image
  preparation and server-controlled animation. Renewal never replaces an open
  paywall or records a user tap/delivery; cached taps retain queued analytics.

## 1.4.0 — 2026-11-01

- Add automatic lifecycle history, configurable session/day/active-minute thresholds,
  host readiness and 30-day pending signals with visibility-based completion.
- Add durable delayed follow-ups, source-policy revalidation and separate cancellation outcomes.
- Fix prepared-host sizing, follow-up binding, dismissal attribution and presentation concurrency.
- Add smooth motion styles, reverse transitions, reduced motion and instant open/close.
- Expected lifecycle no-display decisions remain diagnostic rather than error logs.
- Update lifecycle, billing and integration documentation. No Flutter build/run/tests performed.

## 1.3.1 - 2026-10-30

- Revalidate trigger delivery with the backend before showing, including prepared presentation; discard cached/prepared content on a no-display decision. Cached HTML is no longer authorization to display offline. Network failures do not deliver stale paywalls.
- Detach hidden prepared WebViews after loading or failure. Suspend CSS/Web Animations, animation-frame callbacks and media while hidden or backgrounded; resume on presentation. Keep SDK paint readiness independent of suspended content frames.
- Handle malformed bridge messages safely and deactivate a prepared paywall when its last host unmounts.
- Integrations must respect `show: false` and must not open a native/default paywall as a fallback.

## 1.3.0 - 2026-10-26

- Add optional push notifications: `setPushToken` / `clearPushToken` register the app's FCM token for the current user and language (no Firebase dependency in the SDK), `trackNotificationOpened` reports a tap and returns the trigger to open, and `handleNotificationOpened` also presents it.
- Add `prepareTrigger(triggerKey)`: loads a trigger's paywall and keeps it prepared, so one outside your usual prepared set (for example the one a notification points at) opens painted instead of as a blank page.

## 1.2.1 - 2026-10-18

- Keep one prepared paywall by default (`configurePreparedPaywallPool` previously defaulted to 0), so `MySuperWallHost` actually keeps the preferred trigger warm and `handleTrigger` no longer rebuilds the WebView on every presentation. Pass `maxCount: 0` to opt out.
- Add `initialize(locale:)` so the paywall language is set before anything is cached.
- Document the startup preparation step and that per-presentation `setLocale` / `setProductPrices` calls with new values discard the prepared paywall.

## 1.2.0

- Keep prepared WebViews mounted so the first opening can animate without a fixed paint timeout.
- Add SDK log levels (`all`, `warning`, `error`, `none`), defaulting to warnings and errors.
- Use the fixed MySuperWall endpoint and remove the client base URL API.
- Prevent concurrent presentations and clean up timers, queues and prepared controllers on disposal.
- Expose per-trigger lifecycle states and emit impressions once after transition and WebView paint readiness while foregrounded.
- Preserve localized store price cache invalidation from 1.1.6.

# Changelog

## 1.1.5 - 2026-10-15

- Document manifest and rule evaluation APIs.
- Correct the logger minimum to 2.4.0 for DateTimeFormat support.
- Accept both shimmer 3.x and 4.x without raising the SDK minimum.
- Apply core Dart lint and formatting fixes.

## 1.1.4 - 2026-10-15

- Redesign the package README with branded paywall artwork, product highlights, a guided quick start and expandable technical references.
- Clarify purchase callbacks, connectivity behavior and host dependency compatibility.
- No runtime API changes.

## 1.1.3 - 2026-10-15

- Prepare the first pub.dev release with MIT licensing, package metadata and an explicit publication allowlist.
- Declare Android/iOS support and the actual Flutter 3.35 / Dart 3.9 minimum required by shared_preferences 2.5.4.
- Retain the compatible package_info_plus and device_info_plus version ranges introduced in 1.1.2.

## 1.1.2 - 2026-10-15

- Accept package_info_plus 9.x and 10.x (`>=9.0.0 <11.0.0`).
- Accept device_info_plus 11.5+, 12.x and 13.x (`>=11.5.0 <14.0.0`).
- Preserve the host application's compatible plugin versions without dependency overrides.
- Reviewed the consumed Dart APIs in cached versions; no Flutter build, run,
  dependency resolution or tests were executed for this metadata-only change.

## 1.1.1 - 2026-10-15

- Add bounded automatic follow-up paywalls, independent country/language selection,
  scoped manifest caches and stale-response protection.

## 1.1.0 - 2026-10-13

- **0 ms Latency (Offline Cache & Local Rule Engine):**
  - Download and persist self-contained active paywall & rules manifest on cold start.
  - Evaluate triggers locally in-memory (0ms) using deterministic SHA-256 bucketing, semantic versioning, and audience targeting.
  - Background manifest sync using ETag / 304 validation for minimal bandwidth consumption.
  - Offline event queueing (`OfflineEventQueue`) for non-blocking analytics ingestion.
  - 100% backwards-compatible fail-safe fallback to network prefetch when no manifest is cached.

## 1.0.8 - 2026-07-27

- Faster paywall loading: assets are now cached as files on disk.
- Fixed an HTML injection issue in paywall rendering.
- Fixed a loop in the JavaScript back-button bridge.
- Locale changes now purge cached paywalls so the new language is fetched.

## 1.0.7 - 2026-05-06

- Paywall presentation can be configured from the dashboard: transition style, duration, curve and dismiss behavior (`PaywallPresentationConfig`).
- Improved prepared-paywall host and session handling (`MySuperWallHost`).
- `MySuperWallProductDataEntry` computes per-day/week/month price text from a single price.
- Added presentation unit tests.

## 1.0.6 - 2026-04-09

- Added `setStructuredProductData` and `MySuperWallProductDataEntry` for intro-offer prices and eligibility.

## 1.0.3 - 1.0.5 - 2026-03

- Early releases: paywall dismiss support and paywall session fixes.
