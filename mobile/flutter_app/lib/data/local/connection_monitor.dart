import 'dart:async';

import 'package:flutter/foundation.dart';

/// Whether the *farm server* is reachable right now.
///
/// Deliberately not a WiFi/radio check. A tablet parked in a greenhouse
/// can be joined to an access point with no route to the office server,
/// and a phone hotspot can show four bars over a dead backhaul — both
/// report "connected" to the OS while every request times out. So the
/// truth here comes from actual request outcomes: [ApiClient] reports what
/// happened, and once something fails this polls a cheap health endpoint
/// on a backoff until the server answers again.
///
/// Starting [online] optimistic matters: the first request of a session
/// should go to the network rather than be pre-emptively queued.
class ConnectionMonitor extends ChangeNotifier {
  ConnectionMonitor({required Future<bool> Function() probe}) : _probe = probe;

  final Future<bool> Function() _probe;

  bool _online = true;
  DateTime? _lastOnlineAt;
  Timer? _timer;
  int _backoffStep = 0;

  /// Called on the offline → online edge. The sync controller hangs the
  /// outbox flush off this: coming back into range is the whole trigger,
  /// no button press required.
  VoidCallback? onReconnected;

  bool get online => _online;
  bool get offline => !_online;
  DateTime? get lastOnlineAt => _lastOnlineAt;

  /// Backoff between health pings while offline. Caps at a minute: a
  /// tablet in a field for three hours must not spend its battery
  /// retrying, but a worker walking back into the yard should see the
  /// sync start on its own within a minute of arriving.
  static const List<Duration> _backoff = [
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 40),
    Duration(seconds: 60),
  ];

  void reportSuccess() {
    _lastOnlineAt = DateTime.now();
    _backoffStep = 0;
    _timer?.cancel();
    _timer = null;
    if (_online) return;
    _online = true;
    notifyListeners();
    onReconnected?.call();
  }

  /// Report only a *transport* failure — an unreachable host or a timeout.
  /// A 403 or a 422 means the server answered, so it must not flip the
  /// tablet into offline mode.
  void reportFailure() {
    if (_online) {
      _online = false;
      notifyListeners();
    }
    _scheduleProbe();
  }

  /// Force an immediate check — the "Try now" button in the sync panel,
  /// and once on app resume.
  Future<bool> checkNow() async {
    final reachable = await _safeProbe();
    if (reachable) {
      reportSuccess();
    } else {
      reportFailure();
    }
    return reachable;
  }

  Future<bool> _safeProbe() async {
    try {
      return await _probe();
    } catch (_) {
      return false;
    }
  }

  void _scheduleProbe() {
    if (_timer != null) return;
    final delay = _backoff[_backoffStep.clamp(0, _backoff.length - 1)];
    if (_backoffStep < _backoff.length - 1) _backoffStep++;
    _timer = Timer(delay, () async {
      _timer = null;
      if (_online) return;
      if (await _safeProbe()) {
        reportSuccess();
      } else {
        _scheduleProbe();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
