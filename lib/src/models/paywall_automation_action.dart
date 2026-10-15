class MySuperWallAutomationAction {
  const MySuperWallAutomationAction({
    required this.type,
    required this.triggerKey,
    required this.sourceEvent,
    this.delayMs = 0,
    this.oncePerSession = true,
    this.cooldownMs = 0,
    this.maxChainDepth = 2,
    this.skipIfPremium = false,
    this.preventRepeatPaywall = true,
    this.ruleKey,
    this.sourceTriggerKey,
    this.sourcePaywallId,
  });

  final String type;
  final String triggerKey;
  final String sourceEvent;
  final int delayMs;
  final bool oncePerSession;
  final int cooldownMs;
  final int maxChainDepth;
  final bool skipIfPremium;
  final bool preventRepeatPaywall;
  final String? ruleKey;
  final String? sourceTriggerKey;
  final String? sourcePaywallId;

  bool get isTriggerAction => type == 'trigger' && triggerKey.trim().isNotEmpty;

  factory MySuperWallAutomationAction.fromJson(Map<String, dynamic> json) {
    int parseInt(dynamic value, int fallback) {
      if (value is int) return value;
      return int.tryParse(value?.toString() ?? '') ?? fallback;
    }

    bool parseBool(dynamic value, bool fallback) {
      if (value is bool) return value;
      final normalized = value?.toString().trim().toLowerCase();
      if (normalized == 'true') return true;
      if (normalized == 'false') return false;
      return fallback;
    }

    return MySuperWallAutomationAction(
      type: json['type']?.toString().trim() ?? '',
      triggerKey: json['triggerKey']?.toString().trim() ?? '',
      sourceEvent: json['sourceEvent']?.toString().trim() ?? '',
      delayMs: parseInt(json['delayMs'], 0),
      oncePerSession: parseBool(json['oncePerSession'], true),
      cooldownMs: parseInt(json['cooldownMs'], 0),
      maxChainDepth: parseInt(json['maxChainDepth'], 2),
      skipIfPremium: parseBool(json['skipIfPremium'], false),
      preventRepeatPaywall: parseBool(json['preventRepeatPaywall'], true),
      ruleKey: json['ruleKey']?.toString(),
      sourceTriggerKey: json['sourceTriggerKey']?.toString(),
      sourcePaywallId: json['sourcePaywallId']?.toString(),
    );
  }
}
