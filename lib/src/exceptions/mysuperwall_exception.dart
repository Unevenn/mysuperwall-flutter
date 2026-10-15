class MySuperWallException implements Exception {
  const MySuperWallException(
    this.message, {
    this.code,
    this.statusCode,
    this.details,
  });

  final String message;
  final String? code;
  final int? statusCode;
  final Map<String, dynamic>? details;

  @override
  String toString() {
    final buffer = StringBuffer('MySuperWallException: $message');
    if (code != null && code!.isNotEmpty) {
      buffer.write(' [code=$code]');
    }
    if (statusCode != null) {
      buffer.write(' [status=$statusCode]');
    }
    if (details != null && details!.isNotEmpty) {
      buffer.write(' [details=$details]');
    }
    return buffer.toString();
  }
}
