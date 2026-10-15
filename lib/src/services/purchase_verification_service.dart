import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/purchase_verification.dart';

/// Uses the client's injected HTTP transport; no receipt persistence or logging.
class PurchaseVerificationService {
  const PurchaseVerificationService({
    required this.client,
    required this.baseUrl,
    required this.timeout,
  });

  final http.Client client;
  final String baseUrl;
  final Duration timeout;

  Future<PurchaseVerificationResult> verify({
    required String appKey,
    required String productId,
    required StorePurchaseProof proof,
  }) async {
    if (appKey.trim().isEmpty || productId.trim().isEmpty) {
      return const PurchaseVerificationResult(
        verified: false,
        reason: 'invalid_verification_request',
        statusCode: 400,
      );
    }
    final transactionId = proof.transactionId;
    final purchaseToken = proof.purchaseToken;
    final validProof = proof.provider == 'apple'
        ? transactionId != null && RegExp(r'^\d{1,64}$').hasMatch(transactionId)
        : purchaseToken != null &&
              purchaseToken.isNotEmpty &&
              purchaseToken.length <= 8192;
    if (!validProof) {
      return const PurchaseVerificationResult(
        verified: false,
        reason: 'invalid_purchase_proof',
        statusCode: 400,
      );
    }
    final body = jsonEncode({
      'appKey': appKey.trim(),
      'productId': productId,
      ...proof.toRequestFields(),
    });
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final response = await client
            .post(
              Uri.parse('${baseUrl}paywall/purchase/verify'),
              headers: {'Content-Type': 'application/json'},
              body: body,
            )
            .timeout(timeout);
        if (response.statusCode >= 500 && attempt < 2) {
          await Future<void>.delayed(
            Duration(milliseconds: 500 * (1 << attempt)),
          );
          continue;
        }
        Object? decoded;
        try {
          decoded = jsonDecode(response.body);
        } on FormatException {
          return PurchaseVerificationResult(
            verified: false,
            reason: 'invalid_verification_response',
            statusCode: response.statusCode,
          );
        }
        if (decoded is! Map<String, dynamic>) {
          return PurchaseVerificationResult(
            verified: false,
            reason: 'invalid_verification_response',
            statusCode: response.statusCode,
          );
        }
        final amount = decoded['amountUsd'];
        return PurchaseVerificationResult(
          verified: response.statusCode == 200 && decoded['verified'] == true,
          duplicate: decoded['duplicate'] == true,
          provider: decoded['provider'] is String
              ? decoded['provider'] as String
              : null,
          environment: decoded['environment'] is String
              ? decoded['environment'] as String
              : null,
          amountUsd: amount is num && amount.isFinite
              ? amount.toDouble()
              : null,
          reason: decoded['reason'] is String
              ? decoded['reason'] as String
              : null,
          statusCode: response.statusCode,
        );
      } on TimeoutException {
        if (attempt == 2) break;
      } on http.ClientException {
        if (attempt == 2) break;
      } catch (_) {
        return const PurchaseVerificationResult(
          verified: false,
          reason: 'verification_transport_error',
        );
      }
      await Future<void>.delayed(Duration(milliseconds: 500 * (1 << attempt)));
    }
    return const PurchaseVerificationResult(
      verified: false,
      reason: 'verification_transport_unavailable',
    );
  }
}
