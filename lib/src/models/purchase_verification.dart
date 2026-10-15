/// Store-issued proof. Never put receipts/tokens in analytics metadata.
class StorePurchaseProof {
  const StorePurchaseProof.apple({required String transactionId})
    : provider = 'apple',
      transactionId = transactionId,
      purchaseToken = null,
      purchaseType = null;

  const StorePurchaseProof.googleProduct({required String purchaseToken})
    : provider = 'google',
      transactionId = null,
      purchaseToken = purchaseToken,
      purchaseType = 'one_time';

  const StorePurchaseProof.googleSubscription({required String purchaseToken})
    : provider = 'google',
      transactionId = null,
      purchaseToken = purchaseToken,
      purchaseType = 'subscription';

  final String provider;
  final String? transactionId;
  final String? purchaseToken;
  final String? purchaseType;

  Map<String, String> toRequestFields() => {
    'provider': provider,
    if (transactionId case final String value) 'transactionId': value,
    if (purchaseToken case final String value) 'purchaseToken': value,
    if (purchaseType case final String value) 'purchaseType': value,
  };
}

/// Transaction verification is analytics proof, not user entitlement authority.
class PurchaseVerificationResult {
  const PurchaseVerificationResult({
    required this.verified,
    this.duplicate = false,
    this.provider,
    this.environment,
    this.amountUsd,
    this.reason,
    this.statusCode,
  });

  final bool verified;
  final bool duplicate;
  final String? provider;
  final String? environment;
  final double? amountUsd;
  final String? reason;
  final int? statusCode;

  bool get retryable {
    final code = statusCode;
    return code == null || code == 429 || code >= 500;
  }
}
