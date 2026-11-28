import '../../api/api_client.dart';

/// The farm's own clock (audit I-16, architecture/ADR-008-OFFLINE-MILK-CLEARANCE.md).
///
/// The morning or the afternoon milking, and the hour a milking entered
/// for an earlier day is dated, are the farm's — Asia/Beirut on Origami —
/// whatever zone the tablet or the browser is set to. The server gives the
/// farm's zone and its offset from UTC with each daylight-saving change for
/// the next year (`GET /farms/me` → `clock`), so a tablet set to another
/// zone, or offline for months, still reads the farm's hour. Until the
/// farm's clock is known (a first start offline, the demo farm), the
/// device's own clock is used, as before.
class FarmClock {
  FarmClock({this.timezone, List<FarmUtcOffset> offsets = const []})
      : _offsets = [...offsets]..sort((a, b) => a.from.compareTo(b.from));

  /// `{"timezone": "Asia/Beirut", "offsets": [{"from": iso, "offset_minutes": 120}, ...]}`
  factory FarmClock.fromJson(Map<String, dynamic> json) => FarmClock(
        timezone: json['timezone'] as String?,
        offsets: [
          for (final o in (json['offsets'] as List<dynamic>? ?? const []))
            if (o is Map && DateTime.tryParse('${o['from']}') != null && o['offset_minutes'] is num)
              FarmUtcOffset(DateTime.parse('${o['from']}').toUtc(), Duration(minutes: (o['offset_minutes'] as num).toInt())),
        ],
      );

  /// The clock the app reads; the farm's once [load] found it.
  static FarmClock current = FarmClock();

  /// Reads the farm's clock (cached for offline like any read) and makes
  /// it [current]. Keeps the one there was when the server cannot say.
  static Future<void> load(ApiClient api) async {
    try {
      final farm = await api.get('/farms/me');
      final clock = farm is Map ? farm['clock'] : null;
      if (clock is Map) {
        final parsed = FarmClock.fromJson(clock.cast<String, dynamic>());
        if (parsed.known) current = parsed;
      }
    } catch (_) {
      // The device's own clock until the farm's is known.
    }
  }

  final String? timezone;
  final List<FarmUtcOffset> _offsets;

  bool get known => _offsets.isNotEmpty;

  /// The farm's offset from UTC at [at] (the device's own when unknown).
  Duration offsetAt(DateTime at) {
    if (_offsets.isEmpty) return at.toLocal().timeZoneOffset;
    final u = at.toUtc();
    var hit = _offsets.first;
    for (final o in _offsets) {
      if (o.from.isAfter(u)) break;
      hit = o;
    }
    return hit.offset;
  }

  /// The farm's wall clock at [at]: read its year, month, day and hour
  /// (a UTC value that carries the farm's time of day).
  DateTime wallTime(DateTime at) => _offsets.isEmpty ? at.toLocal() : at.toUtc().add(offsetAt(at));

  int hourAt(DateTime at) => wallTime(at).hour;

  /// The farm's calendar day of [at], as a date.
  DateTime farmDay(DateTime at) {
    final w = wallTime(at);
    return DateTime(w.year, w.month, w.day);
  }

  bool isFarmToday(DateTime day, {DateTime? now}) {
    final today = farmDay(now ?? DateTime.now());
    return day.year == today.year && day.month == today.month && day.day == today.day;
  }

  /// The instant it is [hour]:00 on the farm's [day].
  DateTime instantOf(DateTime day, int hour) {
    if (_offsets.isEmpty) return DateTime(day.year, day.month, day.day, hour);
    final wall = DateTime.utc(day.year, day.month, day.day, hour);
    final guess = wall.subtract(offsetAt(wall));
    // Across a daylight-saving change the offset at the guess decides.
    return wall.subtract(offsetAt(guess));
  }

  /// The milking the farm is at: the morning one before 13:00 on its clock.
  String milkSessionAt(DateTime at) => milkSessionForHour(hourAt(at));

  String milkSessionNow() => milkSessionAt(DateTime.now());
}

/// From [from] (UTC) the farm's clock is UTC + [offset].
class FarmUtcOffset {
  const FarmUtcOffset(this.from, this.offset);
  final DateTime from;
  final Duration offset;
}

/// The milking of an hour of the day: the morning one before 13:00, the
/// afternoon / evening one after.
String milkSessionForHour(int hour) => hour < 13 ? 'morning' : 'evening';
