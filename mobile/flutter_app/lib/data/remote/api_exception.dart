/// Thrown for anything that reached the server and got a non-2xx back.
/// [detail] is the FarmOS contract's own user-facing error string — see
/// docs/FARMOS_API.md "`detail` is shown to the farmer verbatim" — safe to
/// show directly in a snackbar/dialog.
class ApiException implements Exception {
  ApiException(this.statusCode, this.detail);
  final int statusCode;
  final String detail;

  bool get isAuthError => statusCode == 401 || statusCode == 403;

  @override
  String toString() => 'ApiException($statusCode): $detail';
}

/// Thrown when the request never got a response at all — no connectivity,
/// DNS failure, timeout, server unreachable. Every repository in this app
/// treats this the same as "we're offline": fall back to SQLite / demo
/// data rather than surfacing a network error to the worker mid-task.
class ApiOfflineException implements Exception {
  ApiOfflineException([this.message = 'The server could not be reached.']);
  final String message;

  @override
  String toString() => 'ApiOfflineException: $message';
}
