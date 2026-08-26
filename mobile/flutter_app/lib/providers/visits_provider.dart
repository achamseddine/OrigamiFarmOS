import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../data/demo/visits_demo_data.dart';
import '../data/local/farm_write_service.dart' show WriteResult;
import '../domain/entities/mouneh.dart';
import '../domain/entities/visits.dart';
import '../visits/analytics.dart' as analytics;
import '../visits/visits_write_service.dart';
import 'feed_provider.dart';
import 'mouneh_provider.dart';
import '../sync/sync_queue_controller.dart';

const _uuid = Uuid();

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

/// Provider for the Farm Visits & Agri-Tourism module — same shape as
/// [MounehProvider]: in-memory state seeded from demo data, mutated only
/// after [VisitsWriteService] confirms the offline write succeeded.
///
/// Depends directly on [FeedProvider] and [MounehProvider] for the two
/// Farm Shop / Visitor POS deduction paths (RULE-VIS-006) — a visitor
/// retail sale always deducts real stock through the *owning* module's own
/// write service, never by mutating another module's table directly.
class VisitsProvider extends ChangeNotifier {
  VisitsProvider({
    required VisitsWriteService writeService,
    required SyncQueueController syncQueue,
    required FeedProvider feedProvider,
    required MounehProvider mounehProvider,
  })  : _writeService = writeService,
        _syncQueue = syncQueue,
        _feedProvider = feedProvider,
        _mounehProvider = mounehProvider,
        _license = const ModuleLicense(moduleCode: kVisitsModuleCode, status: 'active', plan: 'visits_experience', activatedBy: 'user-super-1'),
        _calendar = {for (final d in VisitsDemoData.openingCalendar) d.weekday: d},
        _sessions = List.of(VisitsDemoData.sessions),
        _packages = List.of(VisitsDemoData.packages),
        _activities = List.of(VisitsDemoData.activities),
        _visitors = List.of(VisitsDemoData.visitors),
        _bookings = List.of(VisitsDemoData.bookings),
        _staffRoster = List.of(VisitsDemoData.staffRoster),
        _costs = List.of(VisitsDemoData.costs),
        _retailSales = List.of(VisitsDemoData.retailSales),
        _feedback = List.of(VisitsDemoData.feedback),
        _incidents = List.of(VisitsDemoData.incidents);

  final VisitsWriteService _writeService;
  final SyncQueueController _syncQueue;
  final FeedProvider _feedProvider;
  final MounehProvider _mounehProvider;

  ModuleLicense _license;
  final Map<int, VisitOpeningCalendarDay> _calendar;
  List<VisitSession> _sessions;
  List<VisitPackage> _packages;
  List<VisitActivity> _activities;
  List<VisitorProfile> _visitors;
  List<VisitBooking> _bookings;
  List<VisitStaffRosterEntry> _staffRoster;
  List<VisitCost> _costs;
  List<VisitRetailSale> _retailSales;
  List<VisitorFeedbackEntry> _feedback;
  List<VisitIncident> _incidents;

  ModuleLicense get license => _license;
  bool get isActive => _license.isActive;
  List<VisitOpeningCalendarDay> get calendar => [for (var w = 0; w < 7; w++) _calendar[w] ?? VisitOpeningCalendarDay(weekday: w)];
  List<VisitSession> get sessions => List.unmodifiable([..._sessions]..sort((a, b) => a.date.compareTo(b.date)));
  List<VisitPackage> get packages => List.unmodifiable(_packages);
  List<VisitActivity> get activities => List.unmodifiable(_activities);
  List<VisitorProfile> get visitors => List.unmodifiable(_visitors);
  List<VisitBooking> get bookings => List.unmodifiable([..._bookings]..sort((a, b) => b.createdAt.compareTo(a.createdAt)));
  List<VisitStaffRosterEntry> get staffRoster => List.unmodifiable(_staffRoster);
  List<VisitCost> get costs => List.unmodifiable(_costs);
  List<VisitRetailSale> get retailSales => List.unmodifiable(_retailSales);
  List<VisitorFeedbackEntry> get feedback => List.unmodifiable(_feedback);
  List<VisitIncident> get incidents => List.unmodifiable(_incidents);

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

  // -------------------------------------------------------------- License
  Future<void> setModuleActive(bool active) async {
    final status = active ? 'active' : 'inactive';
    final result = await _writeService.setModuleStatus(moduleCode: kVisitsModuleCode, status: status);
    if (result.success) {
      _license = _license.copyWith(status: status);
      notifyListeners();
    }
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
    final result = await _writeService.upsertCalendarDay(weekday: weekday, isOpen: isOpen, openTime: openTime, closeTime: closeTime, defaultCapacity: defaultCapacity, notes: notes);
    if (result.success) {
      _calendar[weekday] = VisitOpeningCalendarDay(weekday: weekday, isOpen: isOpen, openTime: openTime, closeTime: closeTime, defaultCapacity: defaultCapacity, notes: notes);
      _syncQueue.enqueue(entityType: 'visit_opening_calendar', entityId: 'weekday-$weekday', operation: 'update');
      notifyListeners();
    }
    return result;
  }

  // -------------------------------------------------------------- Sessions
  Future<WriteResult> createSession({required DateTime date, required String startTime, required String endTime, int? capacity, String? weatherNote, double? expectedStaffCost}) async {
    final defaultCap = _calendar[(date.weekday - 1) % 7]?.defaultCapacity ?? 0;
    final resolvedCapacity = capacity ?? defaultCap;
    if (resolvedCapacity <= 0) return const WriteResult.fail('Set a capacity greater than zero (or configure a default for this weekday first).');
    final id = _uuid.v4();
    final result = await _writeService.createSession(id: id, date: date, startTime: startTime, endTime: endTime, capacity: resolvedCapacity, weatherNote: weatherNote, expectedStaffCost: expectedStaffCost);
    if (result.success) {
      _sessions.add(VisitSession(id: id, date: date, startTime: startTime, endTime: endTime, capacity: resolvedCapacity, weatherNote: weatherNote, expectedStaffCost: expectedStaffCost));
      _syncQueue.enqueue(entityType: 'visit_session', entityId: id, operation: 'create');
      notifyListeners();
    }
    return result;
  }

  Future<WriteResult> updateSession({required String id, int? capacity, String? status, String? weatherNote}) async {
    final index = _sessions.indexWhere((s) => s.id == id);
    if (index == -1) return const WriteResult.fail('Session not found.');
    final result = await _writeService.updateSession(id: id, capacity: capacity, status: status, weatherNote: weatherNote);
    if (result.success) {
      _sessions[index] = _sessions[index].copyWith(capacity: capacity, status: status, weatherNote: weatherNote);
      _syncQueue.enqueue(entityType: 'visit_session', entityId: id, operation: 'update');
      notifyListeners();
    }
    return result;
  }

  // -------------------------------------------------------------- Packages
  Future<WriteResult> createPackage({required String name, String? description, double basePrice = 0, String currency = 'USD', int? durationMinutes}) async {
    if (name.trim().isEmpty) return const WriteResult.fail('Give the package a name.');
    final id = _uuid.v4();
    final result = await _writeService.createPackage(id: id, name: name, description: description, basePrice: basePrice, currency: currency, durationMinutes: durationMinutes);
    if (result.success) {
      _packages.add(VisitPackage(id: id, name: name, description: description, basePrice: basePrice, currency: currency, durationMinutes: durationMinutes));
      _syncQueue.enqueue(entityType: 'visit_package', entityId: id, operation: 'create');
      notifyListeners();
    }
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
    final id = _uuid.v4();
    final result = await _writeService.createActivity(
      id: id,
      name: name,
      activityType: activityType,
      price: price,
      capacityPerSlot: capacityPerSlot,
      durationMinutes: durationMinutes,
      requiresStaffRole: requiresStaffRole,
      requiresAnimalId: requiresAnimalId,
      maxUsesPerDay: maxUsesPerDay,
    );
    if (result.success) {
      _activities.add(VisitActivity(
        id: id,
        name: name,
        activityType: activityType,
        price: price,
        capacityPerSlot: capacityPerSlot,
        durationMinutes: durationMinutes,
        requiresStaffRole: requiresStaffRole,
        requiresAnimalId: requiresAnimalId,
        maxUsesPerDay: maxUsesPerDay,
      ));
      _syncQueue.enqueue(entityType: 'visit_activity', entityId: id, operation: 'create');
      notifyListeners();
    }
    return result;
  }

  // -------------------------------------------------------------- Visitors
  Future<WriteResult> _createVisitor({required String fullName, String? phone, String? email, String preferredLanguage = 'en', String? notes, bool consentMarketing = false}) async {
    final id = _uuid.v4();
    final result = await _writeService.createVisitor(id: id, fullName: fullName, phone: phone, email: email, preferredLanguage: preferredLanguage, notes: notes, consentMarketing: consentMarketing);
    if (result.success) {
      _visitors.add(VisitorProfile(id: id, fullName: fullName, phone: phone, email: email, preferredLanguage: preferredLanguage, notes: notes, consentMarketing: consentMarketing));
    }
    return result;
  }

  Future<WriteResult> createVisitor({required String fullName, String? phone, String? email, String preferredLanguage = 'en', String? notes, bool consentMarketing = false}) async {
    final result = await _createVisitor(fullName: fullName, phone: phone, email: email, preferredLanguage: preferredLanguage, notes: notes, consentMarketing: consentMarketing);
    if (result.success) notifyListeners();
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

  int _activityBookedQuantity(String activityId, DateTime scheduledAt) {
    var total = 0;
    for (final b in _bookings) {
      if (b.status == 'cancelled' || b.status == 'no_show') continue;
      for (final a in b.activities) {
        if (a.activityId == activityId && a.scheduledAt.isAtSameMomentAs(scheduledAt)) total += a.quantity;
      }
    }
    return total;
  }

  int _sessionConfirmedGuestCount(String sessionId) =>
      _bookings.where((b) => b.sessionId == sessionId && (b.status == 'confirmed' || b.status == 'checked_in' || b.status == 'completed')).fold<int>(0, (sum, b) => sum + b.guestCount);

  Set<String> _sessionAssignedRoles(String sessionId) => staffForSession(sessionId).map((r) => r.role).toSet();

  /// RULE-VIS-002/004/005/008/010: creates a draft booking. Pass either
  /// [visitorId] (existing visitor) or the `newVisitor*` fields for a
  /// walk-in — never both. Activity capacity and animal-welfare limits are
  /// enforced here at creation time; session capacity and handler
  /// assignment are enforced later, at [confirmBooking] time, matching the
  /// backend engine exactly.
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
    if (idempotencyKey != null) {
      final existing = _firstWhere(_bookings, (b) => b.id == idempotencyKey);
      if (existing != null) return const WriteResult.ok();
    }
    final guestCount = adults + children;
    if (guestCount <= 0) return const WriteResult.fail('A booking needs at least one guest.');
    final session = sessionById(sessionId);
    final package = packageById(packageId);
    if (session == null) return const WriteResult.fail('Session not found.');
    if (package == null) return const WriteResult.fail('Package not found.');

    var resolvedVisitorId = visitorId;
    if (resolvedVisitorId == null) {
      if (newVisitorFullName == null || newVisitorFullName.trim().isEmpty) {
        return const WriteResult.fail('Pick an existing visitor or enter a name for the walk-in guest.');
      }
      final visitorResult = await _createVisitor(fullName: newVisitorFullName, phone: newVisitorPhone, email: newVisitorEmail);
      if (!visitorResult.success) return visitorResult;
      resolvedVisitorId = _visitors.last.id;
    }

    double activityRevenue = 0;
    final activityLines = <Map<String, Object?>>[];
    final bookingActivities = <VisitBookingActivity>[];
    for (final sel in activitySelections) {
      final activity = activityById(sel.activityId);
      if (activity == null) return WriteResult.fail('Unknown activity: ${sel.activityId}');
      try {
        analytics.validateActivityCapacity(capacityPerSlot: activity.capacityPerSlot, alreadyBooked: _activityBookedQuantity(activity.id, sel.scheduledAt), requested: sel.quantity);
        analytics.validateWelfareLimit(maxUsesPerDay: activity.maxUsesPerDay, usesToday: activityUsesOnDay(activity.id, sel.scheduledAt), requested: sel.quantity);
      } on ArgumentError catch (e) {
        return WriteResult.fail(e.message.toString());
      }
      activityRevenue += activity.price * sel.quantity;
      activityLines.add({'activity_id': activity.id, 'scheduled_at': sel.scheduledAt.toIso8601String(), 'quantity': sel.quantity, 'unit_price': activity.price, 'status': 'scheduled'});
      bookingActivities.add(VisitBookingActivity(activityId: activity.id, scheduledAt: sel.scheduledAt, quantity: sel.quantity, unitPrice: activity.price));
    }

    final packageRevenue = package.basePrice * guestCount;
    final totalAmount = packageRevenue + activityRevenue;
    final id = idempotencyKey ?? _uuid.v4();

    final result = await _writeService.createBooking(
      id: id,
      visitorId: resolvedVisitorId,
      sessionId: sessionId,
      packageId: packageId,
      adults: adults,
      children: children,
      totalAmount: totalAmount,
      balanceDue: totalAmount,
      source: source,
      notes: notes,
      idempotencyKey: idempotencyKey,
      activities: activityLines,
    );
    if (result.success) {
      _bookings.add(VisitBooking(
        id: id,
        visitorId: resolvedVisitorId,
        sessionId: sessionId,
        packageId: packageId,
        adults: adults,
        children: children,
        totalAmount: totalAmount,
        balanceDue: totalAmount,
        source: source,
        notes: notes,
        activities: bookingActivities,
        createdAt: DateTime.now(),
      ));
      _syncQueue.enqueue(entityType: 'visit_booking', entityId: id, operation: 'create');
      notifyListeners();
    }
    return result;
  }

  Future<WriteResult> _transition(String bookingId, String nextStatus, String? timestampColumn) async {
    final index = _bookings.indexWhere((b) => b.id == bookingId);
    if (index == -1) return const WriteResult.fail('Booking not found.');
    final booking = _bookings[index];
    try {
      analytics.validateStatusTransition(booking.status, nextStatus);
    } on ArgumentError catch (e) {
      return WriteResult.fail(e.message.toString());
    }

    if (nextStatus == 'confirmed') {
      final session = sessionById(booking.sessionId);
      if (session == null) return const WriteResult.fail('Session not found.');
      try {
        analytics.validateSessionCapacity(capacity: session.capacity, alreadyBooked: _sessionConfirmedGuestCount(booking.sessionId), requested: booking.guestCount);
        final assignedRoles = _sessionAssignedRoles(booking.sessionId);
        for (final a in booking.activities) {
          final activity = activityById(a.activityId);
          analytics.validateHandlerAssignment(requiresStaffRole: activity?.requiresStaffRole, assignedRoles: assignedRoles);
        }
      } on ArgumentError catch (e) {
        return WriteResult.fail(e.message.toString());
      }
    }

    final result = await _writeService.updateBookingStatus(id: bookingId, status: nextStatus, timestampColumn: timestampColumn);
    if (result.success) {
      final now = DateTime.now();
      _bookings[index] = booking.copyWith(
        status: nextStatus,
        confirmedAt: timestampColumn == 'confirmed_at' ? now : null,
        checkedInAt: timestampColumn == 'checked_in_at' ? now : null,
        completedAt: timestampColumn == 'completed_at' ? now : null,
        cancelledAt: timestampColumn == 'cancelled_at' ? now : null,
      );
      _syncQueue.enqueue(entityType: 'visit_booking', entityId: bookingId, operation: 'update');
      notifyListeners();
    }
    return result;
  }

  Future<WriteResult> confirmBooking(String bookingId) => _transition(bookingId, 'confirmed', 'confirmed_at');
  Future<WriteResult> checkInBooking(String bookingId) => _transition(bookingId, 'checked_in', 'checked_in_at');
  Future<WriteResult> completeBooking(String bookingId) => _transition(bookingId, 'completed', 'completed_at');
  Future<WriteResult> noShowBooking(String bookingId) => _transition(bookingId, 'no_show', null);
  Future<WriteResult> cancelBooking(String bookingId) => _transition(bookingId, 'cancelled', 'cancelled_at');
  Future<WriteResult> refundBooking(String bookingId) => _transition(bookingId, 'refunded', null);

  // ---------------------------------------------------- Staff & direct costs
  double _hoursBetween(String start, String end) {
    final s = start.split(':');
    final e = end.split(':');
    final startMinutes = int.parse(s[0]) * 60 + int.parse(s[1]);
    final endMinutes = int.parse(e[0]) * 60 + int.parse(e[1]);
    final diff = endMinutes - startMinutes;
    return diff > 0 ? diff / 60.0 : 0;
  }

  Future<WriteResult> addStaffRoster({required String sessionId, required String workerId, String? workerName, required String role, required String startTime, required String endTime, double hourlyRate = 0}) async {
    if (sessionById(sessionId) == null) return const WriteResult.fail('Session not found.');
    final totalCost = _hoursBetween(startTime, endTime) * hourlyRate;
    final id = _uuid.v4();
    final result = await _writeService.addStaffRoster(id: id, sessionId: sessionId, workerId: workerId, workerName: workerName, role: role, startTime: startTime, endTime: endTime, hourlyRate: hourlyRate, totalCost: totalCost);
    if (result.success) {
      _staffRoster.add(VisitStaffRosterEntry(id: id, sessionId: sessionId, workerId: workerId, workerName: workerName ?? workerId, role: role, startTime: startTime, endTime: endTime, hourlyRate: hourlyRate, totalCost: totalCost));
      _syncQueue.enqueue(entityType: 'visit_staff_roster', entityId: id, operation: 'create');
      notifyListeners();
    }
    return result;
  }

  Future<WriteResult> addCost({required String sessionId, required String category, String? description, required double amount, String allocationMethod = 'per_session'}) async {
    if (amount <= 0) return const WriteResult.fail('Amount must be greater than zero.');
    final id = _uuid.v4();
    final result = await _writeService.addCost(id: id, sessionId: sessionId, category: category, description: description, amount: amount, allocationMethod: allocationMethod);
    if (result.success) {
      _costs.add(VisitCost(id: id, sessionId: sessionId, category: category, description: description, amount: amount, allocationMethod: allocationMethod));
      _syncQueue.enqueue(entityType: 'visit_cost', entityId: id, operation: 'create');
      notifyListeners();
    }
    return result;
  }

  // -------------------------------------------------- Farm Shop / Visitor POS
  /// RULE-VIS-006: deducts a plain inventory item through [FeedProvider]'s
  /// own write service, then records the visitor-facing sale.
  Future<WriteResult> recordInventoryRetailSale({String? bookingId, String? visitorId, String channel = 'farm_shop', required String inventoryItemId, required double quantity, required double unitPrice}) async {
    if (quantity <= 0) return const WriteResult.fail('Quantity must be greater than zero.');
    final deduction = await _feedProvider.recordDistribution(itemId: inventoryItemId, quantityKg: quantity, reason: 'visitor_retail_sale', linkedEntityType: 'visit_retail_sale', linkedEntityId: bookingId);
    if (!deduction.success) return deduction;
    return _persistRetailSale(bookingId: bookingId, visitorId: visitorId, channel: channel, totalAmount: quantity * unitPrice);
  }

  /// RULE-VIS-006: deducts Mouneh finished-goods stock through
  /// [MounehProvider]'s own write service (mirrors `record_sale` on the
  /// backend), then records the visitor-facing sale.
  Future<WriteResult> recordMounehRetailSale({String? bookingId, String? visitorId, String channel = 'farm_shop', required String finishedGoodsStockId, required double quantity, required double unitPrice}) async {
    if (quantity <= 0) return const WriteResult.fail('Quantity must be greater than zero.');
    final stock = _firstWhere(_mounehProvider.finishedGoods, (s) => s.id == finishedGoodsStockId);
    if (stock == null) return const WriteResult.fail('Stock record not found.');
    final deduction = await _mounehProvider.recordSale(productId: stock.productId, finishedGoodsStockId: stock.id, quantity: quantity, unitPrice: unitPrice, channel: 'retail');
    if (!deduction.success) return deduction;
    return _persistRetailSale(bookingId: bookingId, visitorId: visitorId, channel: channel, totalAmount: quantity * unitPrice);
  }

  Future<WriteResult> _persistRetailSale({String? bookingId, String? visitorId, required String channel, required double totalAmount}) async {
    final id = _uuid.v4();
    final result = await _writeService.recordRetailSale(id: id, bookingId: bookingId, visitorId: visitorId, channel: channel, totalAmount: totalAmount);
    if (result.success) {
      _retailSales.add(VisitRetailSale(id: id, bookingId: bookingId, visitorId: visitorId, channel: channel, totalAmount: totalAmount, soldAt: DateTime.now()));
      _syncQueue.enqueue(entityType: 'visit_retail_sale', entityId: id, operation: 'create');
      notifyListeners();
    }
    return result;
  }

  // ------------------------------------------------------- Feedback & incidents
  Future<WriteResult> addFeedback({required String bookingId, required int rating, String? comments, bool? wouldReturn}) async {
    if (rating < 1 || rating > 5) return const WriteResult.fail('Rating must be between 1 and 5.');
    final id = _uuid.v4();
    final result = await _writeService.addFeedback(id: id, bookingId: bookingId, rating: rating, comments: comments, wouldReturn: wouldReturn);
    if (result.success) {
      _feedback.add(VisitorFeedbackEntry(id: id, bookingId: bookingId, rating: rating, comments: comments, wouldReturn: wouldReturn, submittedAt: DateTime.now()));
      _syncQueue.enqueue(entityType: 'visitor_feedback', entityId: id, operation: 'create');
      notifyListeners();
    }
    return result;
  }

  Future<WriteResult> addIncident({required String sessionId, String? bookingId, required String incidentType, String severity = 'low', required String description, String? actionTaken}) async {
    final id = _uuid.v4();
    final result = await _writeService.addIncident(id: id, sessionId: sessionId, bookingId: bookingId, incidentType: incidentType, severity: severity, description: description, actionTaken: actionTaken);
    if (result.success) {
      _incidents.add(VisitIncident(id: id, sessionId: sessionId, bookingId: bookingId, incidentType: incidentType, severity: severity, description: description, actionTaken: actionTaken, createdAt: DateTime.now()));
      _syncQueue.enqueue(entityType: 'visit_incident', entityId: id, operation: 'create');
      notifyListeners();
    }
    return result;
  }

  // ------------------------------------------------------------ Analytics
  /// Every "Analytics formulas" line from tech spec v0.6 §9, computed from
  /// granular components rather than trusting `booking.totalAmount` — see
  /// `backend/app/visits/analytics.py`'s doc comment for why (avoids
  /// double-counting activity revenue already folded into a booking's
  /// stored total).
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
      if (start != null && end != null) return !r.soldAt.isBefore(start) && r.soldAt.isBefore(end.add(const Duration(days: 1)));
      return true;
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
