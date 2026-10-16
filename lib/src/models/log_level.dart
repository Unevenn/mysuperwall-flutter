/// Controls SDK log output in debug, profile, and release builds.
enum MySuperWallLogLevel {
  /// Every SDK log message.
  all,

  /// Warnings and errors (the default).
  warning,

  /// Errors only.
  error,

  /// No SDK log output.
  none,
}
