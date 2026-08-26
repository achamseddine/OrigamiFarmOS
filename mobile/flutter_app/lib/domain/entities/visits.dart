/// Farm Visits & Agri-Tourism module — local domain entities (tech spec
/// v0.6 §4). Field names mirror `backend/app/domain/visits_models.py` so
/// payloads round-trip cleanly once sync is wired to the real API.
///
/// The module license itself reuses [ModuleLicense] from
/// `domain/entities/mouneh.dart` — one generic license class backs every
/// licensed module on both the backend and here, exactly like
/// `mouneh_models.ModuleLicense` is reused for `module_code =
/// "visits_agritourism"` on the server.
library;

const String kVisitsModuleCode = 'visits_agritourism';

const List<String> kVisitSessionStatuses = ['open', 'full', 'closed', 'cancelled', 'completed'];
const List<String> kVisitBookingStatuses = ['draft', 'confirmed', 'checked_in', 'completed', 'cancelled', 'no_show', 'refunded'];
const List<String> kVisitBookingSources = ['manual', 'whatsapp', 'website', 'phone', 'walk_in'];
const List<String> kVisitActivityTypes = ['tour', 'ride', 'workshop', 'tasting', 'event', 'other'];
const List<String> kVisitCostCategories = ['staff', 'cleaning', 'utilities', 'tasting', 'marketing', 'safety', 'maintenance', 'other'];
const List<String> kVisitCostAllocationMethods = ['per_session', 'per_guest', 'per_package', 'per_activity'];
const List<String> kVisitRetailChannels = ['farm_shop', 'tasting_upgrade', 'delivery_after_visit'];
const List<String> kVisitIncidentTypes = ['safety', 'animal', 'weather', 'payment', 'complaint', 'other'];
const List<String> kVisitIncidentSeverities = ['low', 'medium', 'high'];

/// RULE-VIS-003: opening days are configurable per farm, never hard-coded.
class VisitOpeningCalendarDay {
  const VisitOpeningCalendarDay({
    required this.weekday, // 0=Monday .. 6=Sunday
    this.isOpen = false,
    this.openTime,
    this.closeTime,
    this.defaultCapacity = 0,
    this.notes,
  });

  final int weekday;
  final bool isOpen;
  final String? openTime; // "HH:MM"
  final String? closeTime;
  final int defaultCapacity;
  final String? notes;

  VisitOpeningCalendarDay copyWith({bool? isOpen, String? openTime, String? closeTime, int? defaultCapacity, String? notes}) => VisitOpeningCalendarDay(
        weekday: weekday,
        isOpen: isOpen ?? this.isOpen,
        openTime: openTime ?? this.openTime,
        closeTime: closeTime ?? this.closeTime,
        defaultCapacity: defaultCapacity ?? this.defaultCapacity,
        notes: notes ?? this.notes,
      );
}

class VisitSession {
  const VisitSession({
    required this.id,
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.capacity,
    this.status = 'open',
    this.weatherNote,
    this.expectedStaffCost,
  });

  final String id;
  final DateTime date;
  final String startTime;
  final String endTime;
  final int capacity;
  final String status;
  final String? weatherNote;
  final double? expectedStaffCost;

  VisitSession copyWith({int? capacity, String? status, String? weatherNote, double? expectedStaffCost}) => VisitSession(
        id: id,
        date: date,
        startTime: startTime,
        endTime: endTime,
        capacity: capacity ?? this.capacity,
        status: status ?? this.status,
        weatherNote: weatherNote ?? this.weatherNote,
        expectedStaffCost: expectedStaffCost ?? this.expectedStaffCost,
      );
}

/// A sellable bundled experience — created dynamically through the
/// Package Builder; nothing here is a fixed catalog entry.
class VisitPackage {
  const VisitPackage({
    required this.id,
    required this.name,
    this.description,
    this.basePrice = 0,
    this.currency = 'USD',
    this.durationMinutes,
    this.active = true,
  });

  final String id;
  final String name;
  final String? description;
  final double basePrice;
  final String currency;
  final int? durationMinutes;
  final bool active;
}

/// An individual bookable activity — "Horse Ride" is only ever demo data
/// (see data/demo/visits_demo_data.dart); a manager can create any
/// activity through the Activity Manager screen.
class VisitActivity {
  const VisitActivity({
    required this.id,
    required this.name,
    this.activityType = 'other',
    this.price = 0,
    this.capacityPerSlot = 1,
    this.durationMinutes,
    this.requiresStaffRole,
    this.requiresAnimalId,
    this.maxUsesPerDay,
    this.active = true,
  });

  final String id;
  final String name;
  final String activityType;
  final double price;
  final int capacityPerSlot;
  final int? durationMinutes;
  final String? requiresStaffRole;
  final String? requiresAnimalId;
  final int? maxUsesPerDay; // welfare_limit_json.max_uses_per_day, flattened for the mobile model
  final bool active;
}

class VisitorProfile {
  const VisitorProfile({
    required this.id,
    required this.fullName,
    this.phone,
    this.email,
    this.preferredLanguage = 'en',
    this.notes,
    this.consentMarketing = false,
  });

  final String id;
  final String fullName;
  final String? phone;
  final String? email;
  final String preferredLanguage;
  final String? notes;
  final bool consentMarketing;
}

class VisitBookingActivity {
  const VisitBookingActivity({
    required this.activityId,
    required this.scheduledAt,
    this.quantity = 1,
    this.unitPrice = 0,
    this.status = 'scheduled', // scheduled | completed | cancelled | missed
  });

  final String activityId;
  final DateTime scheduledAt;
  final int quantity;
  final double unitPrice;
  final String status;

  VisitBookingActivity copyWith({String? status}) => VisitBookingActivity(
        activityId: activityId,
        scheduledAt: scheduledAt,
        quantity: quantity,
        unitPrice: unitPrice,
        status: status ?? this.status,
      );
}

/// A visitor reservation. Status transitions are validated by
/// `lib/visits/analytics.dart::validateStatusTransition` (RULE-VIS-008);
/// every transition is written as an event by `VisitsWriteService`, never
/// silently overwritten.
class VisitBooking {
  const VisitBooking({
    required this.id,
    required this.visitorId,
    required this.sessionId,
    required this.packageId,
    this.status = 'draft',
    this.adults = 1,
    this.children = 0,
    this.totalAmount = 0,
    this.depositAmount = 0,
    this.balanceDue = 0,
    this.source = 'manual',
    this.notes,
    this.activities = const [],
    required this.createdAt,
    this.confirmedAt,
    this.checkedInAt,
    this.completedAt,
    this.cancelledAt,
  });

  final String id;
  final String visitorId;
  final String sessionId;
  final String packageId;
  final String status;
  final int adults;
  final int children;
  final double totalAmount;
  final double depositAmount;
  final double balanceDue;
  final String source;
  final String? notes;
  final List<VisitBookingActivity> activities;
  final DateTime createdAt;
  final DateTime? confirmedAt;
  final DateTime? checkedInAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;

  int get guestCount => adults + children;
  bool get isDraft => status == 'draft';
  bool get isConfirmed => status == 'confirmed';
  bool get isCheckedIn => status == 'checked_in';

  VisitBooking copyWith({
    String? status,
    double? totalAmount,
    double? balanceDue,
    List<VisitBookingActivity>? activities,
    DateTime? confirmedAt,
    DateTime? checkedInAt,
    DateTime? completedAt,
    DateTime? cancelledAt,
  }) =>
      VisitBooking(
        id: id,
        visitorId: visitorId,
        sessionId: sessionId,
        packageId: packageId,
        status: status ?? this.status,
        adults: adults,
        children: children,
        totalAmount: totalAmount ?? this.totalAmount,
        depositAmount: depositAmount,
        balanceDue: balanceDue ?? this.balanceDue,
        source: source,
        notes: notes,
        activities: activities ?? this.activities,
        createdAt: createdAt,
        confirmedAt: confirmedAt ?? this.confirmedAt,
        checkedInAt: checkedInAt ?? this.checkedInAt,
        completedAt: completedAt ?? this.completedAt,
        cancelledAt: cancelledAt ?? this.cancelledAt,
      );
}

class VisitStaffRosterEntry {
  const VisitStaffRosterEntry({
    required this.id,
    required this.sessionId,
    required this.workerId,
    required this.workerName,
    required this.role,
    required this.startTime,
    required this.endTime,
    this.hourlyRate = 0,
    this.totalCost = 0,
  });

  final String id;
  final String sessionId;
  final String workerId;
  final String workerName;
  final String role;
  final String startTime;
  final String endTime;
  final double hourlyRate;
  final double totalCost;
}

class VisitCost {
  const VisitCost({
    required this.id,
    required this.sessionId,
    required this.category,
    this.description,
    this.amount = 0,
    this.allocationMethod = 'per_session',
  });

  final String id;
  final String sessionId;
  final String category;
  final String? description;
  final double amount;
  final String allocationMethod;
}

class VisitRetailSale {
  const VisitRetailSale({
    required this.id,
    this.bookingId,
    this.visitorId,
    required this.channel,
    required this.totalAmount,
    required this.soldAt,
  });

  final String id;
  final String? bookingId;
  final String? visitorId;
  final String channel;
  final double totalAmount;
  final DateTime soldAt;
}

class VisitorFeedbackEntry {
  const VisitorFeedbackEntry({
    required this.id,
    required this.bookingId,
    required this.rating,
    this.comments,
    this.wouldReturn,
    required this.submittedAt,
  });

  final String id;
  final String bookingId;
  final int rating;
  final String? comments;
  final bool? wouldReturn;
  final DateTime submittedAt;
}

class VisitIncident {
  const VisitIncident({
    required this.id,
    required this.sessionId,
    this.bookingId,
    required this.incidentType,
    this.severity = 'low',
    required this.description,
    this.actionTaken,
    required this.createdAt,
  });

  final String id;
  final String sessionId;
  final String? bookingId;
  final String incidentType;
  final String severity;
  final String description;
  final String? actionTaken;
  final DateTime createdAt;
}

/// Per-scope roll-up shown on the Profitability Report (tech spec v0.6 §9).
class VisitProfitability {
  const VisitProfitability({
    required this.packageRevenue,
    required this.activityRevenue,
    required this.retailRevenue,
    required this.visitorRevenue,
    required this.staffCost,
    required this.cleaningUtilitiesCost,
    required this.otherCost,
    required this.directVisitCost,
    required this.grossMargin,
    required this.checkedInVisitors,
    required this.revenuePerVisitor,
    required this.retailConversionPct,
    required this.averageBasketValue,
  });

  final double packageRevenue;
  final double activityRevenue;
  final double retailRevenue;
  final double visitorRevenue;
  final double staffCost;
  final double cleaningUtilitiesCost;
  final double otherCost;
  final double directVisitCost;
  final double grossMargin;
  final int checkedInVisitors;
  final double revenuePerVisitor;
  final double retailConversionPct;
  final double averageBasketValue;
}
