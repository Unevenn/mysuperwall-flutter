import 'dart:convert';
import 'package:crypto/crypto.dart';

import '../models/paywall_manifest.dart';

/// Result of evaluating a trigger against the locally cached manifest.
class TriggerResolution {
  /// Creates a resolution with optional routing and experiment attribution.
  const TriggerResolution({
    required this.show,
    this.paywallId,
    this.abVariant,
    this.isHoldout = false,
    this.matchedRuleName,
    this.reason,
    this.experimentContext,
  });

  final bool show;
  final String? paywallId;
  final String? abVariant;
  final bool isHoldout;
  final String? matchedRuleName;
  final String? reason;
  final Map<String, dynamic>? experimentContext;
}

/// Evaluates audience predicates and deterministic assignments without networking.
class LocalRuleEngine {
  /// Creates a stateless local rule evaluator.
  const LocalRuleEngine();

  /// Deterministic uniform bucket (0..99) using SHA-256 of `userId:salt`.
  /// Identical to backend implementation in `ruleEngine.js`.
  int getDeterministicBucket(String? userId, String salt) {
    if (userId == null || userId.trim().isEmpty) {
      return (DateTime.now().microsecondsSinceEpoch % 100);
    }

    final bytes = utf8.encode('${userId.trim()}:$salt');
    final hashHex = sha256.convert(bytes).toString();
    final intVal = int.parse(hashHex.substring(0, 8), radix: 16);
    return intVal % 100;
  }

  /// Semantic version comparison (v1 vs v2).
  /// 1 if v1 > v2, -1 if v1 < v2, 0 if v1 == v2.
  int compareVersions(String? v1, String? v2) {
    List<int> normalize(String? raw) {
      final s = (raw ?? '').trim().replaceFirst(RegExp(r'^[vV]'), '');
      final clean = s.split(RegExp(r'[-+]'))[0];
      final parts = clean.split('.');
      return parts.map((p) => int.tryParse(p) ?? 0).toList();
    }

    final parts1 = normalize(v1);
    final parts2 = normalize(v2);
    final maxLen = parts1.length > parts2.length
        ? parts1.length
        : parts2.length;

    for (int i = 0; i < maxLen; i++) {
      final p1 = i < parts1.length ? parts1[i] : 0;
      final p2 = i < parts2.length ? parts2[i] : 0;
      if (p1 > p2) return 1;
      if (p1 < p2) return -1;
    }
    return 0;
  }

  dynamic resolveContextValue(Map<String, dynamic> context, String field) {
    if (context.containsKey(field)) return context[field];

    final metadata = context['metadata'];
    if (metadata is Map<String, dynamic> && metadata.containsKey(field)) {
      return metadata[field];
    }

    final userAttributes = context['userAttributes'];
    if (userAttributes is Map<String, dynamic> &&
        userAttributes.containsKey(field)) {
      return userAttributes[field];
    }

    // Support dot notation like "metadata.tier" or "userAttributes.isPro"
    if (field.contains('.')) {
      final parts = field.split('.');
      dynamic current = context;
      for (final part in parts) {
        if (current is Map<String, dynamic> && current.containsKey(part)) {
          current = current[part];
        } else {
          return null;
        }
      }
      return current;
    }

    return null;
  }

  bool evaluateCondition(
    ManifestCondition condition,
    Map<String, dynamic> context,
  ) {
    final actual = resolveContextValue(context, condition.field);
    final target = condition.value;
    final op = condition.operator.toLowerCase().trim();

    switch (op) {
      case 'equals':
      case '==':
      case 'eq':
        return actual?.toString() == target?.toString();

      case 'not_equals':
      case '!=':
      case 'neq':
        return actual?.toString() != target?.toString();

      case 'contains':
        if (actual == null) return false;
        return actual.toString().toLowerCase().contains(
          target.toString().toLowerCase(),
        );

      case 'not_contains':
        if (actual == null) return true;
        return !actual.toString().toLowerCase().contains(
          target.toString().toLowerCase(),
        );

      case 'greater_than':
      case 'gt':
      case '>':
        final aNum = num.tryParse(actual?.toString() ?? '');
        final tNum = num.tryParse(target?.toString() ?? '');
        return aNum != null && tNum != null && aNum > tNum;

      case 'greater_than_or_equal':
      case 'gte':
      case '>=':
        final aNum = num.tryParse(actual?.toString() ?? '');
        final tNum = num.tryParse(target?.toString() ?? '');
        return aNum != null && tNum != null && aNum >= tNum;

      case 'less_than':
      case 'lt':
      case '<':
        final aNum = num.tryParse(actual?.toString() ?? '');
        final tNum = num.tryParse(target?.toString() ?? '');
        return aNum != null && tNum != null && aNum < tNum;

      case 'less_than_or_equal':
      case 'lte':
      case '<=':
        final aNum = num.tryParse(actual?.toString() ?? '');
        final tNum = num.tryParse(target?.toString() ?? '');
        return aNum != null && tNum != null && aNum <= tNum;

      case 'in_list':
      case 'in':
        if (target is List) {
          return target.any((elem) => elem?.toString() == actual?.toString());
        }
        if (target is String) {
          final items = target.split(',').map((s) => s.trim());
          return items.contains(actual?.toString().trim());
        }
        return false;

      case 'not_in_list':
      case 'not_in':
        if (target is List) {
          return !target.any((elem) => elem?.toString() == actual?.toString());
        }
        if (target is String) {
          final items = target.split(',').map((s) => s.trim());
          return !items.contains(actual?.toString().trim());
        }
        return true;

      case 'version_gt':
        return compareVersions(actual?.toString(), target?.toString()) > 0;

      case 'version_gte':
        return compareVersions(actual?.toString(), target?.toString()) >= 0;

      case 'version_lt':
        return compareVersions(actual?.toString(), target?.toString()) < 0;

      case 'version_lte':
        return compareVersions(actual?.toString(), target?.toString()) <= 0;

      case 'version_eq':
        return compareVersions(actual?.toString(), target?.toString()) == 0;

      default:
        return actual?.toString() == target?.toString();
    }
  }

  bool matchesRule(ManifestRule rule, Map<String, dynamic> context) {
    if (rule.conditions.isEmpty) return true;

    final isAny = rule.matchType.toLowerCase() == 'any';
    if (isAny) {
      return rule.conditions.any((c) => evaluateCondition(c, context));
    } else {
      return rule.conditions.every((c) => evaluateCondition(c, context));
    }
  }

  /// Resolves an active trigger entirely in memory (0ms execution).
  TriggerResolution resolveTrigger({
    required ManifestTrigger trigger,
    required String? userId,
    required Map<String, dynamic> context,
  }) {
    // 1. Sort rules by priority descending
    final rules = List<ManifestRule>.from(trigger.rules)
      ..sort((a, b) => b.priority.compareTo(a.priority));

    // 2. Evaluate audience rules
    for (final rule in rules) {
      if (matchesRule(rule, context)) {
        // Holdout evaluation for this rule
        if (rule.holdoutPercentage > 0) {
          final bucket = getDeterministicBucket(userId, '${rule.id}:holdout');
          if (bucket < rule.holdoutPercentage) {
            return TriggerResolution(
              show: false,
              isHoldout: true,
              matchedRuleName: rule.name,
              reason: 'holdout',
            );
          }
        }

        // A/B Variant selection
        if (rule.variants.isNotEmpty) {
          final selected = _selectVariant(
            rule.variants,
            userId,
            '${rule.id}:variant',
          );
          if (selected != null) {
            return TriggerResolution(
              show: true,
              paywallId: selected.paywallId,
              abVariant: selected.variant,
              experimentContext: _context(
                rule.experimentId,
                rule.experimentVersion,
                rule.audienceId,
                selected,
              ),
              matchedRuleName: rule.name,
            );
          }
        }

        // Fallback to rule root paywallId
        if (rule.paywallId != null && rule.paywallId!.isNotEmpty) {
          return TriggerResolution(
            show: true,
            paywallId: rule.paywallId,
            abVariant: 'A',
            experimentContext: _context(
              rule.experimentId,
              rule.experimentVersion,
              rule.audienceId,
              null,
            ),
            matchedRuleName: rule.name,
          );
        }
      }
    }

    // 3. Fallback: Trigger default holdout check
    if (trigger.holdoutPercentage > 0) {
      final bucket = getDeterministicBucket(userId, '${trigger.key}:holdout');
      if (bucket < trigger.holdoutPercentage) {
        return const TriggerResolution(
          show: false,
          isHoldout: true,
          reason: 'holdout',
        );
      }
    }

    // 4. Fallback: Trigger default A/B variants
    if (trigger.variants.isNotEmpty) {
      final selected = _selectVariant(
        trigger.variants,
        userId,
        '${trigger.key}:variant',
      );
      if (selected != null) {
        return TriggerResolution(
          show: true,
          paywallId: selected.paywallId,
          abVariant: selected.variant,
          experimentContext: _context(
            trigger.experimentId,
            trigger.experimentVersion,
            trigger.audienceId,
            selected,
          ),
        );
      }
    }

    // 5. Fallback: Trigger single paywallId
    if (trigger.paywallId != null && trigger.paywallId!.isNotEmpty) {
      return TriggerResolution(
        show: true,
        paywallId: trigger.paywallId,
        abVariant: 'A',
        experimentContext: _context(
          trigger.experimentId,
          trigger.experimentVersion,
          trigger.audienceId,
          null,
        ),
      );
    }

    return const TriggerResolution(
      show: false,
      reason: 'no_paywall_configured',
    );
  }

  Map<String, dynamic>? _context(
    String? id,
    String? version,
    String? audience,
    ManifestVariant? variant,
  ) {
    if (id == null || version == null || variant?.variantId == null) {
      return null;
    }
    return {
      'experimentId': id,
      'experimentVersion': version,
      'audienceId': audience ?? 'root',
      'variantId': variant?.variantId,
      'variantLabel': variant?.variantLabel ?? variant?.variant ?? 'A',
    };
  }

  ManifestVariant? _selectVariant(
    List<ManifestVariant> variants,
    String? userId,
    String salt,
  ) {
    if (variants.isEmpty) return null;
    if (variants.length == 1) return variants.first;

    final totalWeight = variants.fold<int>(0, (sum, v) => sum + v.weight);
    if (totalWeight <= 0) return variants.first;

    final bucket = getDeterministicBucket(userId, salt);
    final scaledBucket = (bucket * totalWeight) ~/ 100;

    int accumulator = 0;
    for (final v in variants) {
      accumulator += v.weight;
      if (scaledBucket < accumulator) {
        return v;
      }
    }

    return variants.last;
  }
}
