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
