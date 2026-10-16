import 'package:logger/logger.dart';

import '../models/log_level.dart';

/// Shared SDK logging policy. Does not change the application's logger settings.
class MySuperWallLogging {
  static MySuperWallLogLevel level = MySuperWallLogLevel.warning;
  static final Logger logger = createLogger();

  static Logger createLogger({LogPrinter? printer}) {
    return Logger(filter: _SdkLogFilter(), printer: printer);
  }
}

class _SdkLogFilter extends LogFilter {
  @override
  bool shouldLog(LogEvent event) {
    switch (MySuperWallLogging.level) {
      case MySuperWallLogLevel.all:
        return true;
      case MySuperWallLogLevel.warning:
        return event.level.value >= Level.warning.value;
      case MySuperWallLogLevel.error:
        return event.level.value >= Level.error.value;
      case MySuperWallLogLevel.none:
        return false;
    }
  }
}
