/// A delivery decision is not necessarily an SDK failure. Keep configuration,
/// audience and lifecycle no-ops out of the error console.
class PaywallDiagnosticPolicy {
  static bool isExpectedNoDisplay(String? reason) => const {
    'trigger_not_found',
    'holdout',
    'paywall_not_assigned',
    'paywall_inactive',
    'no_matching_rule',
    'no_matching_audience',
    'presentation_in_progress',
    'presentation_deferred',
    'identity_changed',
    'sdk_disposed',
    'follow_up_repeat',
  }.contains(reason);
}
