/// Remote mobile paywalls with cached targeting and host-managed purchases.
///
/// Initialize [MySuperWallClient] once, mount [MySuperWallHost] in the existing
/// application builder, and call trigger APIs from your application controller.
/// Purchase and restore callbacks must use the application's billing provider.
library mysuperwall_sdk;

export 'src/mysuperwall_client.dart';
export 'src/product_data_entry.dart';
export 'src/models/paywall_result.dart';
export 'src/models/paywall_data.dart';
export 'src/models/paywall_automation_action.dart';
export 'src/models/paywall_presentation.dart';
export 'src/models/paywall_manifest.dart';
export 'src/services/local_rule_engine.dart';
export 'src/exceptions/mysuperwall_exception.dart';
export 'src/ui/paywall_host.dart';
export 'src/ui/paywall_view.dart';
export 'src/models/purchase_verification.dart';
export 'src/models/log_level.dart';
export 'src/models/paywall_state.dart';
