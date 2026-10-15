import 'paywall_presentation.dart';

class PaywallData {
  const PaywallData({
    required this.id,
    required this.appKey,
    required this.name,
    required this.triggerKey,
    required this.templateKey,
    required this.html,
    required this.contentJson,
    required this.productIds,
    required this.presentation,
    this.abVariant,
    this.experimentContext,
  });

  final String id;
  final String appKey;
  final String name;
  final String triggerKey;
  final String templateKey;
  final String html;
  final Map<String, dynamic> contentJson;
  final List<String> productIds;
  final PaywallPresentationConfig presentation;
  final String? abVariant;
  final Map<String, dynamic>? experimentContext;

  factory PaywallData.fromJson(Map<String, dynamic> json) {
    final contentJson = json['contentJson'];
    final parsedContentJson = contentJson is Map<String, dynamic>
        ? Map<String, dynamic>.from(contentJson)
        : <String, dynamic>{};
    final topLevelPresentation = json['presentation'];
    final mergedContentJson = topLevelPresentation is Map<String, dynamic>
        ? <String, dynamic>{
            ...parsedContentJson,
            'presentation': Map<String, dynamic>.from(topLevelPresentation),
          }
        : parsedContentJson;

    return PaywallData(
      id: (json['id'] ?? '').toString(),
      appKey: (json['appKey'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      triggerKey: (json['triggerKey'] ?? json['event'] ?? '').toString(),
      templateKey: (json['templateKey'] ?? '').toString(),
      html: (json['html'] ?? '').toString(),
      contentJson: mergedContentJson,
      productIds: List<String>.from(json['productIds'] ?? []),
      presentation: PaywallPresentationConfig.fromContentJson(
        mergedContentJson,
      ),
      abVariant: json['abVariant']?.toString(),
      experimentContext: json['experimentContext'] is Map<String, dynamic>
          ? Map<String, dynamic>.unmodifiable(json['experimentContext'])
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'appKey': appKey,
    'name': name,
    'triggerKey': triggerKey,
    'templateKey': templateKey,
    'html': html,
    'contentJson': contentJson,
    'productIds': productIds,
    'presentation': {
      'style': presentation.style.name,
      'durationMs': presentation.duration.inMilliseconds,
      'dismissStyle': presentation.dismissStyle.name,
      if (presentation.dismissable != null)
        'dismissable': presentation.dismissable,
    },
    'abVariant': abVariant,
    if (experimentContext != null) 'experimentContext': experimentContext,
  };
}
