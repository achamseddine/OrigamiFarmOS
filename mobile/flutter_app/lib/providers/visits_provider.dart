import 'package:flutter/foundation.dart';
import '../api/api_client.dart';
import '../domain/entities/mouneh.dart';
import '../domain/entities/user_profile.dart';
import '../domain/entities/visits.dart';
import '../visits/analytics.dart' as analytics;

/// One row of the Activity Manager utilization breakdown on the
/// Profitability Report (tech spec v0.6 §9 "Activity utilization = sold
/// slots / available slots").
class ActivityUtilizationRow {
  const ActivityUtilizationRow({required this.activityId, required this.activityName, required this.soldSlots, required this.availableSlots, required this.utilizationPct});
  final String activityId;
  final String activityName;
  final int soldSlots;
  final int availableSlots;
  final double utilizationPct;
}

/// "Package profitability = package revenue − allocated package costs"
/// (§9) — costs are allocated to a package pro-rata by its share of scoped
/// package revenue.
class PackageProfitabilityRow {
  const PackageProfitabilityRow({required this.packageId, required this.packageName, required this.revenue, required this.allocatedCost, required this.profitability});
  final String packageId;
  final String packageName;
  final double revenue;
  final double allocatedCost;
  final double profitability;
}

typedef ProfitabilityReport = ({VisitProfitability summary, List<ActivityUtilizationRow> activityUtilization, List<PackageProfitabilityRow> packageProfitability});

/// Provider for the Farm Visits & Agri-Tourism module — always online:
/// [load] fetches the farm's real calendar/sessions/packages/activities/
/// visitors/bookings/staff-roster/costs/retail-sales/incidents from the
/// backend, and every write posts straight through, then reloads.
///
/// The Profitability Report is still computed locally (same pure
/// `visits/analytics.dart` engine as before) from the freshly-loaded lists
/// rather than by round-tripping to `GET /reports/visit-profitability`,
/// because [VisitorProfitabilityTab] reads it synchronously on every build
/// as the user flips between scopes — exactly the same trade-off
/// `MounehProvider.previewCost` makes for its cost engine.
class VisitsProvider extends ChangeNotifier {
  VisitsProvider({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  ModuleLicense _license = const ModuleLicense(moduleCode: kVisitsModuleCode, status: 'inactive');
  List<VisitOpeningCalendarDay> _calendarDays = [];
  List<VisitSession> _sessions = [];
  List<VisitPackage> _packages = [];
  List<VisitActivity> _activities = [];
  List<VisitorProfile> _visitors = [];
  List<VisitBooking> _bookings = [];
  List<VisitStaffRosterEntry> _staffRoster = [];
  List<VisitCost> _costs = [];
  List<VisitRetailSale> _retailSales = [];
  List<VisitorFeedbackEntry> _feedback = [];
  List<VisitIncident> _incidents = [];
  List<UserProfile> _roster = [];
  bool loading = false;

  ModuleLicense get license => _license;
  bool get isActive => _license.isActive;
  List<VisitOpeningCalendarDay> get calendar => [for (var w = 0; w < 7; w++) _firstWhere(_calendarDays, (d) => d.weekday == w) ?? VisitOpeningCalendarDay(weekday: w)];
  List<VisitSession> get sessions => List.unmodifiable(_sessions);
  List<VisitPackage> get packages => List.unmodifiable(_packages);
  List<VisitActivity> get activities => List.unmodifiable(_activities);
  List<VisitorProfile> get visitors => List.unmodifiable(_visitors);
  List<VisitBooking> get bookings => List.unmodifiable(_bookings);
  List<VisitStaffRosterEntry> get staffRoster => List.unmodifiable(_staffRoster);
  List<VisitCost> get costs => List.unmodifiable(_costs);
  List<VisitRetailSale> get retailSales => List.unmodifiable(_retailSales);
  List<VisitorFeedbackEntry> get feedback => List.unmodifiable(_feedback);
  List<VisitIncident> get incidents => List.unmodifiable(_incidents);
  /// Farm staff, for the Staff Roster picker — anyone the manager can assign
  /// to work a session (mirrors [TasksProvider.roster]).
  List<UserProfile> get roster => List.unmodifiable(_roster);

  VisitSession? sessionById(String id) => _firstWhere(_sessions, (s) => s.id == id);
  VisitPackage? packageById(String id) => _firstWhere(_packages, (p) => p.id == id);
  VisitActivity? activityById(String id) => _firstWhere(_activities, (a) => a.id == id);
  VisitorProfile? visitorById(String id) => _firstWhere(_visitors, (v) => v.id == id);
  VisitBooking? bookingById(String id) => _firstWhere(_bookings, (b) => b.id == id);

  List<VisitBooking> bookingsForSession(String sessionId) => _bookings.where((b) => b.sessionId == sessionId).toList();
  List<VisitStaffRosterEntry> staffForSession(String sessionId) => _staffRoster.where((r) => r.sessionId == sessionId).toList();
  List<VisitCost> costsForSession(String sessionId) => _costs.where((c) => c.sessionId == sessionId).toList();
  List<VisitIncident> incidentsForSession(String sessionId) => _incidents.where((i) => i.sessionId == sessionId).toList();
  VisitorFeedbackEntry? feedbackForBooking(String bookingId) => _firstWhere(_feedback, (f) => f.bookingId == bookingId);

  List<VisitSession> get upcomingSessions => sessions.where((s) => s.status == 'open' || s.status == 'full').toList();
  List<VisitSession> sessionsOn(DateTime day) => sessions.where((s) => s.date.year == day.year && s.date.month == day.month && s.date.day == day.day).toList();

  // -------------------------------------------------------------- Loading
  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      final statusJson = await _api.get('/modules/visits/status') as Map<String, dynamic>;
      _license = ModuleLicense(moduleCode: kVisitsModuleCode, status: statusJson['status'] as String? ?? 'inactive');
      if (!isActive) {
        _clearData();
        return;
      }

      final results = await Future.wait([
        _api.get('/visit-calendar'),
        _api.get('/visit-sessions'),
        _api.get('/visit-packages'),
        _api.get('/visit-activities'),
        _api.get('/visit-bookings'),
        _api.get('/visit-staff-roster'),
        _api.get('/visit-costs'),
        _api.get('/visit-retail-sales'),
        _api.get('/visit-incidents'),
        _api.get('/visitor-feedback'),
        _api.get('/users'),
      ]);
      _calendarDays = (results[0] as List<dynamic>).map((e) => VisitOpeningCalendarDay.fromJson(e as Map<String, dynamic>)).toList();
      _sessions = (results[1] as List<dynamic>).map((e) => VisitSession.fromJson(e as Map<String, dynamic>)).toList();
      _packages = (results[2] as List<dynamic>).map((e) => VisitPackage.fromJson(e as Map<String, dynamic>)).toList();
      _activities = (results[3] as List<dynamic>).map((e) => VisitActivity.fromJson(e as Map<String, dynamic>)).toList();
      _bookings = (results[4] as List<dynamic>).map((e) => VisitBooking.fromJson(e as Map<String, dynamic>)).toList();
      _roster = (results[10] as List<dynamic>).map((e) => UserProfile.fromJson(e as Map<String, dynamic>)).toList();
      _staffRoster = (results[5] as List<dynamic>).map((e) {
        final json = e as Map<String, dynamic>;
        final name = _firstWhere(_roster, (u) => u.id == json['worker_id'])?.name;
        return VisitStaffRosterEntry.fromJson(json, resolvedWorkerName: name);
      }).toList();
      _costs = (results[6] as List<dynamic>).map((e) => VisitCost.fromJson(e as Map<String, dynamic>)).toList();
      _retailSales = (results[7] as List<dynamic>).map((e) => VisitRetailSale.fromJson(e as Map<String, dynamic>)).toList();
      _incidents = (results[8] as List<dynamic>).map((e) => VisitIncident.fromJson(e as Map<String, dynamic>)).toList();
      _feedback = (results[9] as List<dynamic>).map((e) => VisitorFeedbackEntry.fromJson(e as Map<String, dynamic>)).toList();

      // Visitor CRM listing is permission-gated (RULE-VIS-010: owner/
      // manager/visitor_coordinator only) — an animal/produce/mouneh
      // employee still sees the rest of the module's read-only views, just
      // not the visitor directory itself.
      try {
        final visitorsJson = await _api.get('/visitors') as List<dynamic>;
        _visitors = visitorsJson.map((e) => VisitorProfile.fromJson(e as Map<String, dynamic>)).toList();
      } on ApiException {
        _visitors = [];
      }
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void _clearData() {
    _calendarDays = [];
    _sessions = [];
    _packages = [];
    _activities = [];
    _visitors = [];
    _bookings = [];
    _staffRoster = [];
    _costs = [];
    _retailSales = [];
    _feedback = [];
    _incidents = [];
  }

  // -------------------------------------------------------------- License
  /// Module activation itself is super-user only on the backend
  /// (RULE-VIS-001) — this call only succeeds for that role.
  Future<WriteResult> setModuleActive(bool active) async {
    final action = active ? 'activate' : 'deactivate';
    final result = await _api.write(() => _api.post('/modules/$kVisitsModuleCode/$action'));
    if (result.success) await load();
    return result;
  }

  // ------------------------------------------------------- Opening calendar
  /// RULE-VIS-003: opening days are configurable per farm, never hard-coded.
  Future<WriteResult> upsertCalendarDay({
    required int weekday,
    required bool isOpen,
    String? openTime,
    String? closeTime,
    required int defaultCapacity,
    String? notes,
  }) async {
    final result = await _api.write(() => _api.post('/visit-calendar', body: {
          'weekday': weekday,
          'is_open': isOpen,
          'open_time': openTime,
          'close_time': closeTime,
          'default_capacity': defaultCapacity,
          'notes': notes,
        }));
    if (result.success) await load();
    return result;
  }

  // -------------------------------------------------------------- Sessions
  Future<WriteResult> createSession({required DateTime date, required String startTime, required String endTime, int? capacity, String? weatherNote, double? expectedStaffCost}) async {
    final defaultCap = _firstWhere(_calendarDays, (d) => d.weekday == (date.weekday - 1) % 7)?.defaultCapacity ?? 0;
    final resolvedCapacity = capacity ?? defaultCap;
    if (resolvedCapacity <= 0) return const WriteResult.fail('Set a capacity greater than zero (or configure a default for this weekday first).');
    final result = await _api.write(() => _api.post('/visit-sessions', body: {
          'date': date.toIso8601String().split('T').first,
          'start_time': startTime,
          'end_time': endTime,
          'capacity': resolvedCapacity,
          'weather_note': weatherNote,
          'expected_staff_cost': expectedStaffCost,
        }));
    if (result.success) await load();
    return result;
  }

  Future<WriteResult> updateSession({required String id, int? capacity, String? status, String? weatherNote}) async {
    final result = await _api.write(() => _api.patch('/visit-sessions/$id', body: {
          if (capacity != null) 'capacity': capacity,
          if (status != null) 'status': status,
          if (weatherNote != null) 'weather_note': weatherNote,
        }));
    if (result.success) await load();
    return result;
  }

  // -------------------------------------------------------------- Packages
  Future<WriteResult> createPackage({required String name, String? description, double basePrice = 0, String currency = 'USD', int? durationMinutes}) async {
    if (name.trim().isEmpty) return const WriteResult.fail('Give the package a name.');
    final result = await _api.write(() => _api.post('/visit-packages', body: {
          'name': name,
          'description': description,
          'base_price': basePrice,
          'currency': currency,
          'duration_minutes': durationMinutes,
        }));
    if (result.success) await load();
    return result;
  }

  // ------------------------------------------------------------ Activities
  /// RULE-VIS-010: "Horse Ride" is only ever example data here — a manager
  /// can create any activity through this same call.
  Future<WriteResult> createActivity({
    required String name,
    String activityType = 'other',
    double price = 0,
    int capacityPerSlot = 1,
    int? durationMinutes,
    String? requiresStaffRole,
    String? requiresAnimalId,
    int? maxUsesPerDay,
  }) async {
    if (name.trim().isEmpty) return const WriteResult.fail('Give the activity a name.');
    if (capacityPerSlot <= 0) return const WriteResult.fail('Capacity per slot must be at least 1.');
    final result = await _api.write(() => _api.post('/visit-activities', body: {
          'name': name,
          'activity_type': activityType,
          'price': price,
          'capacity_per_slot': capacityPerSlot,
          'duration_minutes': durationMinutes,
          'requires_staff_role': requiresStaffRole,
          'requires_animal_id': requiresAnimalId,
          'welfare_limit_json': maxUsesPerDay != null ? {'max_uses_per_day': maxUsesPerDay} : null,
        }));
    if (result.success) await load();
    return result;
  }

  // -------------------------------------------------------------- Visitors
  Future<WriteResult> createVisitor({required String fullName, String? phone, String? email, String preferredLanguage = 'en', String? notes, bool consentMarketing = false}) async {
    final result = await _api.write(() => _api.post('/visitors', body: {
          'full_name': fullName,
          'phone': phone,
          'email': email,
          'preferred_language': preferredLanguage,
          'notes': notes,
          'consent_marketing': consentMarketing,
        }));
    if (result.success) await load();
    return result;
  }

  // -------------------------------------------------------------- Bookings
  int activityUsesOnDay(String activityId, DateTime day) {
    var total = 0;
    for (final b in _bookings) {
      if (b.status == 'cancelled' || b.status == 'no_show') continue;
      for (final a in b.activities) {
        if (a.activityId == activityId && a.scheduledAt.year == day.year && a.scheduledAt.month == day.month && a.scheduledAt.day == day.day) {
          total += a.quantity;
        }
      }
    }
    return total;
  }

  /// RULE-VIS-002/004/005/008/010: creates a draft booking. Pass either
  /// [visitorId] (existing visitor) or the `newVisitor*` fields for a
  /// walk-in — never both; the backend creates the walk-in's visitor
  /// profile in the same transaction as the booking. Capacity, welfare-
  /// limit, session-capacity and handler-assignment checks all happen
  /// server-side; a violation comes back as [WriteResult.error].
  Future<WriteResult> createBooking({
    String? visitorId,
    String? newVisitorFullName,
    String? newVisitorPhone,
    String? newVisitorEmail,
    required String sessionId,
    required String packageId,
    int adults = 1,
    int children = 0,
    String source = 'manual',
    String? notes,
    List<({String activityId, DateTime scheduledAt, int quantity})> activitySelections = const [],
    String? idempotencyKey,
  }) async {
    if (adults + children <= 0) return const WriteResult.fail('A booking needs at least one guest.');
    if (visitorId == null && (newVisitorFullName == null || newVisitorFullName.trim().isEmpty)) {
      return const WriteResult.fail('Pick an existing visitor or enter a name for the walk-in guest.');
    }
    final result = await _api.write(() => _api.post('/visit-bookings', body: {
          'visitor_id': visitorId,
          'visitor': visitorId == null
              ? {
                  'full_name': newVisitorFullName,
                  'phone': newVisitorPhone,
                  'email': newVisitorEmail,
                }
              : null,
          'session_id': sessionId,
          'package_id': packageId,
          'adults': adults,
          'children': children,
          'activities': [for (final a in activitySelections) {'activity_id': a.activityId, 'scheduled_at': a.scheduledAt.toIso8601String(), 'quantity': a.quantity}],
          'source': source,
          'notes': notes,
          'idempotency_key': idempotencyKey,
        }));
    if (result.success) await load();
    return result;
  }

  Future<WriteResult> _transition(String bookingId, String path, {Map<String, dynamic>? body}) async {
    final result = await _api.write(() => _api.post('/visit-bookings/$bookingId/$path', body: body));
    if (result.success) await load();
    return result;
  }

  Future<WriteResult> confirmBooking(String bookingId) => _transition(bookingId, 'confirm');
  Future<WriteResult> checkInBooking(String bookingId) => _transition(bookingId, 'check-in');
  Future<WriteResult> completeBooking(String bookingId) => _transition(bookingId, 'complete');
  Future<WriteResult> noShowBooking(String bookingId) => _transition(bookingId, 'no-show');
  Future<WriteResult> cancelBooking(String bookingId, {String? reason}) => _transition(bookingId, 'cancel', body: {'reason': reason, 'refund': false});
  Future<WriteResult> refundBooking(String bookingId) => _transition(bookingId, 'cancel', body: {'refund': true});

  // ---------------------------------------------------- Staff & direct costs
  Future<WriteResult> addStaffRoster({required String sessionId, required String workerId, String? workerName, required String role, required String startTime, required String endTime, double hourlyRate = 0}) async {
    if (sessionById(sessionId) == null) return const WriteResult.fail('Session not found.');
    final result = await _api.write(() => _api.post('/visit-staff-roster', body: {
          'session_id': sessionId,
          'worker_id': workerId,
          'role': role,
          'start_time': startTime,
          'end_time': endTime,
          'hourly_rate': hourlyRate,
        }));
    if (result.success) await load();
    return result;
  }

  Future<WriteResult> addCost({required String sessionId, required String category, String? description, required double amount, String allocationMethod = 'per_session'}) async {
    if (amount <= 0) return const WriteResult.fail('Amount must be greater than zero.');
    final result = await _api.write(() => _api.post('/visit-costs', body: {
          'session_id': sessionId,
          'category': category,
          'description': description,
          'amount': amount,
          'allocation_method': allocationMethod,
        }));
    if (result.success) await load();
    return result;
  }

  // -------------------------------------------------- Farm Shop / Visitor POS
  /// RULE-VIS-006: the backend deducts real stock (a plain inventory item
  /// or Mouneh finished-goods) and records the core `Sale` row atomically
  /// with the visitor-facing retail sale — see `record_retail_sale` in
  /// `app/api/v1/visits.py`.
  Future<WriteResult> recordInventoryRetailSale({String? bookingId, String? visitorId, String channel = 'farm_shop', required String inventoryItemId, required double quantity, required double unitPrice}) {
    if (quantity <= 0) return Future.value(const WriteResult.fail('Quantity must be greater than zero.'));
    return _persistRetailSale(bookingId: bookingId, visitorId: visitorId, channel: channel, lines: [
      {'inventory_item_id': inventoryItemId, 'quantity': quantity, 'unit_price': unitPrice},
    ]);
  }

  Future<WriteResult> recordMounehRetailSale({String? bookingId, String? visitorId, String channel = 'farm_shop', required String finishedGoodsStockId, required double quantity, required double unitPrice}) {
    if (quantity <= 0) return Future.value(const WriteResult.fail('Quantity must be greater than zero.'));
    return _persistRetailSale(bookingId: bookingId, visitorId: visitorId, channel: channel, lines: [
      {'finished_goods_stock_id': finishedGoodsStockId, 'quantity': quantity, 'unit_price': unitPrice},
    ]);
  }

  Future<WriteResult> _persistRetailSale({String? bookingId, String? visitorId, required String channel, required List<Map<String, Object?>> lines}) async {
    final result = await _api.write(() => _api.post('/visit-retail-sales', body: {'booking_id': bookingId, 'visitor_id': visitorId, 'channel': channel, 'lines': lines}));
    if (result.success) await load();
    return result;
  }

  // ------------------------------------------------------- Feedback & incidents
  Future<WriteResult> addFeedback({required String bookingId, required int rating, String? comments, bool? wouldReturn}) async {
    if (rating < 1 || rating > 5) return const WriteResult.fail('Rating must be between 1 and 5.');
    final result = await _api.write(() => _api.post('/visitor-feedback', body: {'booking_id': bookingId, 'rating': rating, 'comments': comments, 'would_return': wouldReturn}));
    if (result.success) await load();
    return result;
  }

  Future<WriteResult> addIncident({required String sessionId, String? bookingId, required String incidentType, String severity = 'low', required String description, String? actionTaken}) async {
    final result = await _api.write(() => _api.post('/visit-incidents', body: {
          'session_id': sessionId,
          'booking_id': bookingId,
          'incident_type': incidentType,
          'severity': severity,
          'description': description,
          'action_taken': actionTaken,
        }));
    if (result.success) await load();
    return result;
  }

  // ------------------------------------------------------------ Analytics
  /// Every "Analytics formulas" line from tech spec v0.6 §9, computed from
  /// granular components rather than trusting `booking.totalAmount` — see
  /// `backend/app/visits/analytics.py`'s doc comment for why (avoids
  /// double-counting activity revenue already folded into a booking's
  /// stored total). A retail sale with no linked booking has no timestamp
  /// from the API (see `VisitRetailSale.soldAt`'s doc comment), so an
  /// unlinked walk-in sale counts toward every scope rather than being
  /// silently dropped from date-range reports.
  ProfitabilityReport profitabilityFor({String? sessionId, DateTime? start, DateTime? end}) {
    final Iterable<VisitSession> scopedSessions;
    if (sessionId != null) {
      scopedSessions = _sessions.where((s) => s.id == sessionId);
    } else if (start != null && end != null) {
      scopedSessions = _sessions.where((s) => !s.date.isBefore(start) && !s.date.isAfter(end));
    } else {
      scopedSessions = _sessions;
    }
    final sessionIds = scopedSessions.map((s) => s.id).toSet();
    final countedBookings = _bookings.where((b) => sessionIds.contains(b.sessionId) && (b.status == 'checked_in' || b.status == 'completed')).toList();

    double packageRevenue = 0;
    double activityRevenue = 0;
    final packageRevenueById = <String, double>{};
    final activitySoldSlots = <String, int>{};
    final activitySessions = <String, Set<String>>{};

    for (final b in countedBookings) {
      final pkg = packageById(b.packageId);
      final rev = (pkg?.basePrice ?? 0) * b.guestCount;
      packageRevenue += rev;
      packageRevenueById.update(b.packageId, (v) => v + rev, ifAbsent: () => rev);
      for (final a in b.activities) {
        activityRevenue += a.quantity * a.unitPrice;
        activitySoldSlots.update(a.activityId, (v) => v + a.quantity, ifAbsent: () => a.quantity);
        activitySessions.putIfAbsent(a.activityId, () => {}).add(b.sessionId);
      }
    }

    final countedBookingIds = countedBookings.map((b) => b.id).toSet();
    final scopedRetail = _retailSales.where((r) {
      if (r.bookingId != null) return countedBookingIds.contains(r.bookingId);
      if (sessionId != null) return false; // a single-session scope needs a booking link to attribute a walk-in sale
      return true; // no per-sale timestamp from the API — include unlinked walk-ins in every other scope
    }).toList();
    final retailRevenue = scopedRetail.fold<double>(0, (sum, r) => sum + r.totalAmount);

    // A single explicitly-chosen session shows all its costs, even ahead of
    // the visit (useful for planning); a multi-session "all time"/date-range
    // scope only counts costs for sessions that have actually happened, so
    // staffing already booked for a future session doesn't drag down a
    // margin that has no matching revenue yet.
    final now = DateTime.now();
    final costSessionIds = sessionId != null ? sessionIds : sessionIds.where((id) => !(sessionById(id)?.date.isAfter(now) ?? false)).toSet();
    final staffCost = _staffRoster.where((r) => costSessionIds.contains(r.sessionId)).fold<double>(0, (sum, r) => sum + r.totalCost);
    final scopedCosts = _costs.where((c) => costSessionIds.contains(c.sessionId)).toList();
    final cleaningUtilitiesCost = scopedCosts.where((c) => c.category == 'cleaning' || c.category == 'utilities').fold<double>(0, (sum, c) => sum + c.amount);
    final otherCost = scopedCosts.where((c) => c.category != 'cleaning' && c.category != 'utilities').fold<double>(0, (sum, c) => sum + c.amount);

    final visitorRevenue = analytics.computeVisitorRevenue(packageRevenue: packageRevenue, activityRevenue: activityRevenue, retailRevenue: retailRevenue);
    final directVisitCost = analytics.computeDirectVisitCost(staffCost: staffCost, activityCost: 0, includedProductCost: 0, cleaningUtilitiesCost: cleaningUtilitiesCost, otherCost: otherCost);
    final grossMargin = analytics.computeGrossMargin(visitorRevenue: visitorRevenue, directVisitCost: directVisitCost);
    final checkedInVisitors = countedBookings.fold<int>(0, (sum, b) => sum + b.guestCount);
    final revenuePerVisitor = analytics.computeRevenuePerVisitor(visitorRevenue: visitorRevenue, checkedInVisitors: checkedInVisitors);

    final visitorsWithPurchase = <String>{};
    for (final r in scopedRetail) {
      if (r.bookingId != null) {
        visitorsWithPurchase.add(r.bookingId!);
      } else if (r.visitorId != null) {
        visitorsWithPurchase.add('visitor:${r.visitorId}');
      }
    }
    final retailConversionPct = analytics.computeRetailConversion(visitorsWithPurchase: visitorsWithPurchase.length, checkedInVisitors: checkedInVisitors);
    final averageBasketValue = analytics.computeAverageBasketValue(retailSalesTotal: retailRevenue, purchaseCount: scopedRetail.length);

    final activityUtilization = [
      for (final entry in activitySoldSlots.entries)
        _buildUtilizationRow(entry.key, entry.value, activitySessions[entry.key]?.length ?? 1),
    ];

    final packageProfitability = [
      for (final entry in packageRevenueById.entries)
        _buildPackageRow(entry.key, entry.value, packageRevenue > 0 ? directVisitCost * (entry.value / packageRevenue) : 0.0),
    ];

    return (
      summary: VisitProfitability(
        packageRevenue: packageRevenue,
        activityRevenue: activityRevenue,
        retailRevenue: retailRevenue,
        visitorRevenue: visitorRevenue,
        staffCost: staffCost,
        cleaningUtilitiesCost: cleaningUtilitiesCost,
        otherCost: otherCost,
        directVisitCost: directVisitCost,
        grossMargin: grossMargin,
        checkedInVisitors: checkedInVisitors,
        revenuePerVisitor: revenuePerVisitor,
        retailConversionPct: retailConversionPct,
        averageBasketValue: averageBasketValue,
      ),
      activityUtilization: activityUtilization,
      packageProfitability: packageProfitability,
    );
  }

  ActivityUtilizationRow _buildUtilizationRow(String activityId, int soldSlots, int sessionCount) {
    final activity = activityById(activityId);
    final availableSlots = (activity?.capacityPerSlot ?? 1) * sessionCount;
    return ActivityUtilizationRow(
      activityId: activityId,
      activityName: activity?.name ?? activityId,
      soldSlots: soldSlots,
      availableSlots: availableSlots,
      utilizationPct: analytics.computeActivityUtilization(soldSlots: soldSlots, availableSlots: availableSlots),
    );
  }

  PackageProfitabilityRow _buildPackageRow(String packageId, double revenue, double allocatedCost) {
    final pkg = packageById(packageId);
    return PackageProfitabilityRow(
      packageId: packageId,
      packageName: pkg?.name ?? packageId,
      revenue: revenue,
      allocatedCost: allocatedCost,
      profitability: analytics.computePackageProfitability(packageRevenue: revenue, allocatedCosts: allocatedCost),
    );
  }

  // ---------------------------------------------------------- Dashboard
  int get todaysSessionCount => sessionsOn(DateTime.now()).length;
  int get draftBookingCount => _bookings.where((b) => b.status == 'draft').length;
  int get confirmedBookingCount => _bookings.where((b) => b.status == 'confirmed').length;
  int get checkedInBookingCount => _bookings.where((b) => b.status == 'checked_in').length;
  double get lifetimeVisitorRevenue => profitabilityFor().summary.visitorRevenue;
  double get lifetimeGrossMargin => profitabilityFor().summary.grossMargin;

  T? _firstWhere<T>(List<T> list, bool Function(T) test) {
    for (final item in list) {
      if (test(item)) return item;
    }
    return null;
  }
}
