class MySuperWallProductDataEntry {
  const MySuperWallProductDataEntry({
    required this.displayPrice,
    this.displayPriceWithPeriod,
    this.priceString,
    this.price,
    this.currencyCode,
    this.subscriptionPeriod,
    this.pricePerDayText,
    this.pricePerWeekText,
    this.pricePerMonthText,
    this.pricePerYearText,
    this.productCategory,
    this.introDisplayPrice,
    this.introDisplayPriceWithPeriod,
    this.introPriceText,
    this.introPriceString,
    this.introPrice,
    this.introSubscriptionPeriod,
    this.introEligible,
    this.introUsed,
  });

  final String displayPrice;
  final String? displayPriceWithPeriod;
  final String? priceString;
  final String? price;
  final String? currencyCode;
  final String? subscriptionPeriod;
  final String? pricePerDayText;
  final String? pricePerWeekText;
  final String? pricePerMonthText;
  final String? pricePerYearText;
  final String? productCategory;
  final String? introDisplayPrice;
  final String? introDisplayPriceWithPeriod;
  final String? introPriceText;
  final String? introPriceString;
  final String? introPrice;
  final String? introSubscriptionPeriod;
  final bool? introEligible;
  final bool? introUsed;

  String? _calculatePrice(String? rawPriceStr, double factor) {
    if (rawPriceStr == null || rawPriceStr.isEmpty) return rawPriceStr;

    final match = RegExp(r'([\d,.]*\d)').firstMatch(rawPriceStr);
    if (match == null) return rawPriceStr;

    final numberStr = match.group(0)!;

    bool commaIsDecimal = false;
    if (numberStr.contains(',') && numberStr.contains('.')) {
      commaIsDecimal = numberStr.lastIndexOf(',') > numberStr.lastIndexOf('.');
    } else if (numberStr.contains(',')) {
      final parts = numberStr.split(',');
      if (parts.length == 2 && parts.last.length != 3) {
        commaIsDecimal = true;
      } else if (parts.length > 2) {
        commaIsDecimal = false;
      } else {
        commaIsDecimal = parts.last.length != 3;
      }
    }

    String normalizedStr = numberStr;
    if (commaIsDecimal) {
      normalizedStr = normalizedStr.replaceAll('.', '').replaceAll(',', '.');
    } else {
      normalizedStr = normalizedStr.replaceAll(',', '');
    }

    final doubleValue = double.tryParse(normalizedStr);
    if (doubleValue == null) return rawPriceStr;

    final calculatedValue = doubleValue * factor;

    String formattedNumberStr = calculatedValue.toStringAsFixed(2);
    if (formattedNumberStr.endsWith('.00')) {
      formattedNumberStr = formattedNumberStr.substring(
        0,
        formattedNumberStr.length - 3,
      );
    }

    if (commaIsDecimal) {
      formattedNumberStr = formattedNumberStr.replaceAll('.', ',');
    }

    return rawPriceStr.replaceFirst(numberStr, formattedNumberStr);
  }

  Map<String, dynamic> toJson() {
    String? autoDayText = pricePerDayText;
    String? autoWeekText = pricePerWeekText;
    String? autoMonthText = pricePerMonthText;
    String? autoYearText = pricePerYearText;

    if (subscriptionPeriod != null) {
      final baseStr = priceString ?? displayPrice;

      if (subscriptionPeriod == 'P1W') {
        autoDayText ??= _calculatePrice(baseStr, 1 / 7);
        autoWeekText ??= baseStr;
        autoMonthText ??= _calculatePrice(baseStr, 4);
        autoYearText ??= _calculatePrice(baseStr, 52);
      } else if (subscriptionPeriod == 'P1M') {
        autoDayText ??= _calculatePrice(baseStr, 1 / 30);
        autoWeekText ??= _calculatePrice(baseStr, 1 / 4);
        autoMonthText ??= baseStr;
        autoYearText ??= _calculatePrice(baseStr, 12);
      } else if (subscriptionPeriod == 'P2M') {
        autoDayText ??= _calculatePrice(baseStr, 1 / 60);
        autoWeekText ??= _calculatePrice(baseStr, 1 / 8);
        autoMonthText ??= _calculatePrice(baseStr, 1 / 2);
        autoYearText ??= _calculatePrice(baseStr, 6);
      } else if (subscriptionPeriod == 'P3M') {
        autoDayText ??= _calculatePrice(baseStr, 1 / 90);
        autoWeekText ??= _calculatePrice(baseStr, 1 / 12);
        autoMonthText ??= _calculatePrice(baseStr, 1 / 3);
        autoYearText ??= _calculatePrice(baseStr, 4);
      } else if (subscriptionPeriod == 'P6M') {
        autoDayText ??= _calculatePrice(baseStr, 1 / 180);
        autoWeekText ??= _calculatePrice(baseStr, 1 / 26);
        autoMonthText ??= _calculatePrice(baseStr, 1 / 6);
        autoYearText ??= _calculatePrice(baseStr, 2);
      } else if (subscriptionPeriod == 'P1Y') {
        autoDayText ??= _calculatePrice(baseStr, 1 / 365);
        autoWeekText ??= _calculatePrice(baseStr, 1 / 52);
        autoMonthText ??= _calculatePrice(baseStr, 1 / 12);
        autoYearText ??= baseStr;
      }
    }

    return {
      'displayPrice': displayPrice,
      'displayPriceWithPeriod': displayPriceWithPeriod ?? displayPrice,
      'priceString': priceString ?? displayPrice,
      'price': price ?? displayPrice,
      if (currencyCode != null) 'currencyCode': currencyCode,
      if (subscriptionPeriod != null) 'subscriptionPeriod': subscriptionPeriod,
      if (autoDayText != null) 'pricePerDayText': autoDayText,
      if (autoWeekText != null) 'pricePerWeekText': autoWeekText,
      if (autoMonthText != null) 'pricePerMonthText': autoMonthText,
      if (autoYearText != null) 'pricePerYearText': autoYearText,
      if (autoDayText != null) 'dailyPriceText': autoDayText,
      if (autoWeekText != null) 'weeklyPriceText': autoWeekText,
      if (autoMonthText != null) 'monthlyPriceText': autoMonthText,
      if (autoYearText != null) 'yearlyPriceText': autoYearText,
      if (productCategory != null) 'productCategory': productCategory,
      if (introDisplayPrice != null) 'introDisplayPrice': introDisplayPrice,
      if (introDisplayPriceWithPeriod != null)
        'introDisplayPriceWithPeriod': introDisplayPriceWithPeriod,
      if (introPriceText != null) 'introPriceText': introPriceText,
      if (introPriceString != null) 'introPriceString': introPriceString,
      if (introPrice != null) 'introPrice': introPrice,
      if (introSubscriptionPeriod != null)
        'introSubscriptionPeriod': introSubscriptionPeriod,
      if (introEligible != null) 'introEligible': introEligible,
      if (introUsed != null) 'introUsed': introUsed,
    };
  }
}
