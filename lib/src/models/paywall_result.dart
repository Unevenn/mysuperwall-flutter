import 'paywall_data.dart';

class PaywallResult {
  const PaywallResult({
    required this.show,
    required this.paywall,
    this.reason,
    this.message,
    this.statusCode,
    this.details,
  });

  final bool show;
  final PaywallData? paywall;
  final String? reason;
  final String? message;
  final int? statusCode;
  final Map<String, dynamic>? details;

  factory PaywallResult.fromJson(Map<String, dynamic> json) {
    PaywallData? paywallData;
    if (json['paywall'] is Map<String, dynamic>) {
      final pwMap = Map<String, dynamic>.from(json['paywall']);
      // Inject root-level abVariant into paywall object if missing
      if (json['abVariant'] != null) {
        pwMap['abVariant'] = json['abVariant'];
      }
      paywallData = PaywallData.fromJson(pwMap);
    }

    return PaywallResult(
      show: json['show'] == true,
      paywall: paywallData,
      reason: json['reason']?.toString(),
      message: json['message']?.toString(),
      statusCode: json['statusCode'] is int ? json['statusCode'] as int : null,
      details: json['details'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(json['details'] as Map<String, dynamic>)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'show': show,
    'paywall': paywall?.toJson(),
    'reason': reason,
    'message': message,
    'statusCode': statusCode,
    'details': details,
  };
}
