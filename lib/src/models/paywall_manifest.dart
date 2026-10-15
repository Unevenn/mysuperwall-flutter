import 'paywall_data.dart';
import 'paywall_presentation.dart';
import 'paywall_result.dart';

/// A single audience predicate evaluated against user or device attributes.
class ManifestCondition {
  /// Creates an immutable manifest configuration.
  const ManifestCondition({
    required this.field,
    required this.operator,
    required this.value,
  });

  /// Attribute name to read from the evaluation context.
  final String field;

  /// Comparison operator supplied by the manifest, such as equals.
  final String operator;

  /// Expected comparison value; its type depends on the operator.
  final dynamic value;

  /// Decodes the server manifest, applying defaults for omitted fields.
  factory ManifestCondition.fromJson(Map<String, dynamic> json) {
    return ManifestCondition(
      field: (json['field'] ?? '').toString(),
      operator: (json['operator'] ?? 'equals').toString(),
      value: json['value'],
    );
  }

  /// Encodes this configuration using the server manifest field names.
  Map<String, dynamic> toJson() => {
    'field': field,
    'operator': operator,
    'value': value,
  };
}

/// A weighted A/B assignment that routes to one paywall.
class ManifestVariant {
  /// Creates an immutable manifest configuration.
  const ManifestVariant({
    this.variantId,
    this.variantLabel,
    required this.variant,
    required this.weight,
    required this.paywallId,
  });

  /// Stable variant key used for assignment and analytics.
  final String variant;

  /// Relative allocation weight used when selecting a variant.
  final int weight;

  /// Identifier of the paywall selected by this configuration.
  final String paywallId;

  /// Backend variant identifier when experiment attribution is available.
  final String? variantId;

  /// Human-readable label for this variant.
  final String? variantLabel;

  /// Decodes the server manifest, applying defaults for omitted fields.
  factory ManifestVariant.fromJson(Map<String, dynamic> json) {
    return ManifestVariant(
      variantId: json['variantId']?.toString(),
      variantLabel: json['variantLabel']?.toString(),
      variant: (json['variant'] ?? 'A').toString(),
      weight: (json['weight'] is num) ? (json['weight'] as num).toInt() : 50,
      paywallId: (json['paywallId'] ?? '').toString(),
    );
  }

  /// Encodes this configuration using the server manifest field names.
  Map<String, dynamic> toJson() => {
    'variantId': variantId,
    'variantLabel': variantLabel,
    'variant': variant,
    'weight': weight,
    'paywallId': paywallId,
  };
}

/// An ordered audience rule with optional experiment and holdout allocation.
class ManifestRule {
  /// Creates an immutable manifest configuration.
  const ManifestRule({
    this.experimentId,
    this.experimentVersion,
    this.audienceId,
    required this.id,
    required this.name,
    required this.priority,
    required this.matchType,
    required this.conditions,
    required this.holdoutPercentage,
    this.paywallId,
    required this.variants,
  });

  /// Stable backend identifier of this audience rule.
  final String id;

  /// Human-readable name used when reporting the matching rule.
  final String name;

  /// Ordering priority used to evaluate audience rules.
  final int priority;

  /// Condition combination mode, typically all or any.
  final String matchType;

  /// Predicates evaluated before this rule can match.
  final List<ManifestCondition> conditions;

  /// Percentage of matching users excluded from the experiment.
  final int holdoutPercentage;

  /// Identifier of the paywall selected by this configuration.
  final String? paywallId;

  /// Weighted alternatives used for deterministic assignment.
  final List<ManifestVariant> variants;

  /// Backend experiment identifier for analytics attribution.
  final String? experimentId;

  /// Version of the experiment allocation represented by this rule.
  final String? experimentVersion;

  /// Backend audience identifier for the matching rule.
  final String? audienceId;

  /// Decodes the server manifest, applying defaults for omitted fields.
  factory ManifestRule.fromJson(Map<String, dynamic> json) {
    return ManifestRule(
      experimentId: json['experimentId']?.toString(),
      experimentVersion: json['experimentVersion']?.toString(),
      audienceId: json['audienceId']?.toString(),
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      priority: (json['priority'] is num)
          ? (json['priority'] as num).toInt()
          : 0,
      matchType: (json['matchType'] ?? 'all').toString(),
      conditions: (json['conditions'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ManifestCondition.fromJson)
          .toList(),
      holdoutPercentage: (json['holdoutPercentage'] is num)
          ? (json['holdoutPercentage'] as num).toInt()
          : 0,
      paywallId: json['paywallId']?.toString(),
      variants: (json['variants'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ManifestVariant.fromJson)
          .toList(),
    );
  }

  /// Encodes this configuration using the server manifest field names.
  Map<String, dynamic> toJson() => {
    'experimentId': experimentId,
    'experimentVersion': experimentVersion,
    'audienceId': audienceId,
    'id': id,
    'name': name,
    'priority': priority,
    'matchType': matchType,
    'conditions': conditions.map((c) => c.toJson()).toList(),
    'holdoutPercentage': holdoutPercentage,
    'paywallId': paywallId,
    'variants': variants.map((v) => v.toJson()).toList(),
  };
}

class ManifestTrigger {
  const ManifestTrigger({
    this.experimentId,
    this.experimentVersion,
    this.audienceId,
    required this.id,
    required this.key,
    required this.prewarmPriority,
    required this.holdoutPercentage,
    this.paywallId,
    required this.variants,
    required this.rules,
    this.dismissFollowUpPaywallId,
  });

  final String id;
  final String key;
  final int prewarmPriority;
  final int holdoutPercentage;
  final String? paywallId;
  final List<ManifestVariant> variants;
  final List<ManifestRule> rules;
  final String? dismissFollowUpPaywallId;

  final String? experimentId;
  final String? experimentVersion;
  final String? audienceId;

  factory ManifestTrigger.fromJson(Map<String, dynamic> json) {
    final dismissAction = json['dismissAction'];
    String? followUpId;
    if (dismissAction is Map<String, dynamic> &&
        dismissAction['type'] == 'follow_up_paywall') {
      followUpId = dismissAction['followUpPaywallId']?.toString();
    }

    return ManifestTrigger(
      experimentId: json['experimentId']?.toString(),
      experimentVersion: json['experimentVersion']?.toString(),
      audienceId: json['audienceId']?.toString(),
      id: (json['id'] ?? '').toString(),
      key: (json['key'] ?? '').toString(),
      prewarmPriority: (json['prewarmPriority'] is num)
          ? (json['prewarmPriority'] as num).toInt()
          : 0,
      holdoutPercentage: (json['holdoutPercentage'] is num)
          ? (json['holdoutPercentage'] as num).toInt()
          : 0,
      paywallId: json['paywallId']?.toString(),
      variants: (json['variants'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ManifestVariant.fromJson)
          .toList(),
      rules: (json['rules'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ManifestRule.fromJson)
          .toList(),
      dismissFollowUpPaywallId: followUpId,
    );
  }

  Map<String, dynamic> toJson() => {
    'experimentId': experimentId,
    'experimentVersion': experimentVersion,
    'audienceId': audienceId,
    'id': id,
    'key': key,
    'prewarmPriority': prewarmPriority,
    'holdoutPercentage': holdoutPercentage,
    'paywallId': paywallId,
    'variants': variants.map((v) => v.toJson()).toList(),
    'rules': rules.map((r) => r.toJson()).toList(),
    'dismissAction': dismissFollowUpPaywallId != null
        ? {
            'type': 'follow_up_paywall',
            'followUpPaywallId': dismissFollowUpPaywallId,
          }
        : {'type': 'none'},
  };
}

class ManifestPaywall {
  const ManifestPaywall({
    required this.id,
    required this.name,
    required this.templateKey,
    required this.html,
    required this.contentJson,
    required this.productIds,
    required this.products,
    this.publishedVersion,
  });

  final String id;
  final String name;
  final String templateKey;
  final String html;
  final Map<String, dynamic> contentJson;
  final List<String> productIds;
  final List<Map<String, dynamic>> products;
  final int? publishedVersion;

  factory ManifestPaywall.fromJson(Map<String, dynamic> json) {
    return ManifestPaywall(
      publishedVersion: (json['publishedVersion'] as num?)?.toInt(),
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      templateKey: (json['templateKey'] ?? '').toString(),
      html: (json['html'] ?? '').toString(),
      contentJson: json['contentJson'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(json['contentJson'])
          : <String, dynamic>{},
      productIds: List<String>.from(json['productIds'] ?? []),
      products: (json['products'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'templateKey': templateKey,
    'html': html,
    'contentJson': contentJson,
    'productIds': productIds,
    'products': products,
    'publishedVersion': publishedVersion,
  };

  PaywallResult toPaywallResult({
    required String triggerKey,
    required String appKey,
    String? abVariant,
    Map<String, dynamic>? experimentContext,
  }) {
    final paywallData = PaywallData(
      id: id,
      appKey: appKey,
      name: name,
      triggerKey: triggerKey,
      templateKey: templateKey,
      html: html,
      contentJson: contentJson,
      productIds: productIds,
      presentation: PaywallPresentationConfig.fromContentJson(contentJson),
      abVariant: abVariant,
      experimentContext: experimentContext == null
          ? null
          : Map<String, dynamic>.unmodifiable({
              ...experimentContext,
              'paywallId': id,
              'paywallVersion': publishedVersion ?? 0,
            }),
    );

    return PaywallResult(show: true, paywall: paywallData);
  }
}

class PaywallManifest {
  const PaywallManifest({
    required this.hash,
    required this.appId,
    required this.triggers,
    required this.paywalls,
  });

  final String hash;
  final String appId;
  final List<ManifestTrigger> triggers;
  final Map<String, ManifestPaywall> paywalls;

  ManifestTrigger? findTrigger(String key) {
    for (final t in triggers) {
      if (t.key == key) return t;
    }
    return null;
  }

  factory PaywallManifest.fromJson(Map<String, dynamic> json) {
    final triggersList = (json['triggers'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(ManifestTrigger.fromJson)
        .toList();

    final paywallsMap = <String, ManifestPaywall>{};
    final rawPaywalls = json['paywalls'];
    if (rawPaywalls is Map<String, dynamic>) {
      for (final entry in rawPaywalls.entries) {
        if (entry.value is Map<String, dynamic>) {
          paywallsMap[entry.key] = ManifestPaywall.fromJson(
            Map<String, dynamic>.from(entry.value),
          );
        }
      }
    }

    return PaywallManifest(
      hash: (json['hash'] ?? '').toString(),
      appId: (json['appId'] ?? '').toString(),
      triggers: triggersList,
      paywalls: paywallsMap,
    );
  }

  Map<String, dynamic> toJson() => {
    'hash': hash,
    'appId': appId,
    'triggers': triggers.map((t) => t.toJson()).toList(),
    'paywalls': paywalls.map((k, v) => MapEntry(k, v.toJson())),
  };
}
