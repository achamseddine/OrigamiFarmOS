import '../../domain/entities/visits.dart';
import 'mouneh_demo_data.dart';

/// Demo dataset for the Farm Visits & Agri-Tourism module. "Horse Ride" and
/// "Cheese Making Workshop" are used purely as EXAMPLES (tech spec v0.6
/// RULE-VIS-010) — nothing about them is special-cased in the module's
/// code, any activity can be created the same way through the Activity
/// Manager. See `backend/app/visits/seed.py` for the equivalent backend
/// dataset (same sessions/bookings, kept in sync by hand).
///
/// RULE-VIS-003: the opening calendar below (Friday/Saturday/Sunday) is
/// only this farm's configured choice, not a hard-coded rule — see
/// `VisitOpeningCalendarDay`'s weekday convention (0=Monday .. 6=Sunday).
class VisitsDemoData {
  VisitsDemoData._();

  static final DateTime _now = DateTime.now();

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static DateTime _nextWeekday(int weekday0) {
    final target = weekday0 + 1; // Dart's DateTime.weekday: Monday=1..Sunday=7
    final today = _dateOnly(_now);
    var diff = (target - today.weekday) % 7;
    if (diff <= 0) diff += 7;
    return today.add(Duration(days: diff));
  }

  static DateTime _lastWeekday(int weekday0) {
    final target = weekday0 + 1;
    final today = _dateOnly(_now);
    var diff = (today.weekday - target) % 7;
    if (diff <= 0) diff += 7;
    return today.subtract(Duration(days: diff));
  }

  static DateTime _at(DateTime day, String hhmm) {
    final parts = hhmm.split(':');
    return DateTime(day.year, day.month, day.day, int.parse(parts[0]), int.parse(parts[1]));
  }

  /// Weekend-only sample calendar for a Lebanese farm context — every other
  /// day starts closed; a manager can flip any of the 7 days on or off from
  /// the Opening Calendar screen.
  static final List<VisitOpeningCalendarDay> openingCalendar = [
    for (var w = 0; w < 7; w++)
      VisitOpeningCalendarDay(
        weekday: w,
        isOpen: w >= 4, // Friday(4), Saturday(5), Sunday(6)
        openTime: w >= 4 ? '09:00' : null,
        closeTime: w >= 4 ? '17:00' : null,
        defaultCapacity: w >= 4 ? 40 : 0,
        notes: w == 5 ? 'Busiest day — confirm extra guide coverage.' : null,
      ),
  ];

  static final DateTime _fri = _nextWeekday(4);
  static final DateTime _sat = _nextWeekday(5);
  static final DateTime _lastSun = _lastWeekday(6);

  static final VisitSession sessionUpcomingFriday = VisitSession(
    id: 'session-upcoming-fri',
    date: _fri,
    startTime: '10:00',
    endTime: '13:00',
    capacity: 40,
    status: 'open',
    expectedStaffCost: 60,
  );

  static final VisitSession sessionUpcomingSaturday = VisitSession(
    id: 'session-upcoming-sat',
    date: _sat,
    startTime: '10:00',
    endTime: '13:00',
    capacity: 40,
    status: 'open',
    expectedStaffCost: 60,
  );

  static final VisitSession sessionCompletedSunday = VisitSession(
    id: 'session-completed-sun',
    date: _lastSun,
    startTime: '10:00',
    endTime: '13:00',
    capacity: 40,
    status: 'completed',
    expectedStaffCost: 60,
  );

  static List<VisitSession> get sessions => [sessionUpcomingFriday, sessionUpcomingSaturday, sessionCompletedSunday];

  static const VisitPackage familyDayPackage = VisitPackage(
    id: 'package-family',
    name: 'Family Farm Day',
    description: 'Guided tour, animal feeding and a mouneh tasting for the whole family.',
    basePrice: 15,
    currency: 'USD',
    durationMinutes: 150,
  );

  static const VisitPackage schoolVisitPackage = VisitPackage(
    id: 'package-school',
    name: 'School Harvest Visit',
    description: 'Educational tour and harvest walk for school groups.',
    basePrice: 8,
    currency: 'USD',
    durationMinutes: 120,
  );

  static const List<VisitPackage> packages = [familyDayPackage, schoolVisitPackage];

  /// RULE-VIS-004/005: capacity, duration, price and a required staff role
  /// are all just fields on this row — nothing about "Horse Ride" is
  /// special-cased in code, any farm activity works the same way.
  static const VisitActivity horseRideActivity = VisitActivity(
    id: 'activity-horse-ride',
    name: 'Horse Ride',
    activityType: 'ride',
    price: 12,
    capacityPerSlot: 4,
    durationMinutes: 20,
    requiresStaffRole: 'horse_handler',
    requiresAnimalId: 'horse-h07', // Thunder — see data/demo/demo_data.dart
    maxUsesPerDay: 10, // animal welfare limit, RULE-VIS-004
  );

  static const VisitActivity cheeseWorkshopActivity = VisitActivity(
    id: 'activity-cheese-workshop',
    name: 'Cheese Making Workshop',
    activityType: 'workshop',
    price: 10,
    capacityPerSlot: 12,
    durationMinutes: 45,
  );

  static const List<VisitActivity> activities = [horseRideActivity, cheeseWorkshopActivity];

  static const VisitorProfile visitorNadine = VisitorProfile(
    id: 'visitor-nadine',
    fullName: 'Nadine Aoun',
    phone: '+961 3 111 222',
    email: 'nadine.aoun@example.com',
    consentMarketing: true,
  );

  static const VisitorProfile visitorKarim = VisitorProfile(
    id: 'visitor-karim',
    fullName: 'Karim Fares',
    phone: '+961 70 333 444',
    preferredLanguage: 'ar',
  );

  static const VisitorProfile visitorSchool = VisitorProfile(
    id: 'visitor-school',
    fullName: 'Beirut International School',
    phone: '+961 1 555 666',
    email: 'trips@bis.example.edu',
    notes: 'School group contact: Ms. Rita.',
  );

  static const List<VisitorProfile> visitors = [visitorNadine, visitorKarim, visitorSchool];

  static final VisitStaffRosterEntry rosterGuideFriday = VisitStaffRosterEntry(
    id: 'roster-guide-fri',
    sessionId: sessionUpcomingFriday.id,
    workerId: 'user-rami',
    workerName: 'Rami Haddad',
    role: 'guide',
    startTime: '09:30',
    endTime: '13:30',
    hourlyRate: 8,
    totalCost: 32,
  );

  static final VisitStaffRosterEntry rosterHandlerFriday = VisitStaffRosterEntry(
    id: 'roster-handler-fri',
    sessionId: sessionUpcomingFriday.id,
    workerId: 'user-worker-1',
    workerName: 'Joseph Matta',
    role: 'horse_handler',
    startTime: '09:30',
    endTime: '13:30',
    hourlyRate: 7,
    totalCost: 28,
  );

  static final VisitStaffRosterEntry rosterGuideSunday = VisitStaffRosterEntry(
    id: 'roster-guide-sun',
    sessionId: sessionCompletedSunday.id,
    workerId: 'user-rami',
    workerName: 'Rami Haddad',
    role: 'guide',
    startTime: '09:30',
    endTime: '13:30',
    hourlyRate: 8,
    totalCost: 32,
  );

  static final VisitStaffRosterEntry rosterHandlerSunday = VisitStaffRosterEntry(
    id: 'roster-handler-sun',
    sessionId: sessionCompletedSunday.id,
    workerId: 'user-worker-1',
    workerName: 'Joseph Matta',
    role: 'horse_handler',
    startTime: '09:30',
    endTime: '13:30',
    hourlyRate: 7,
    totalCost: 28,
  );

  static List<VisitStaffRosterEntry> get staffRoster => [rosterGuideFriday, rosterHandlerFriday, rosterGuideSunday, rosterHandlerSunday];

  static final VisitCost cleaningCostSunday = VisitCost(
    id: 'cost-cleaning-sun',
    sessionId: sessionCompletedSunday.id,
    category: 'cleaning',
    description: 'Post-visit cleaning',
    amount: 20,
  );

  static final VisitCost utilitiesCostSunday = VisitCost(
    id: 'cost-utilities-sun',
    sessionId: sessionCompletedSunday.id,
    category: 'utilities',
    description: 'Water & electricity',
    amount: 12,
  );

  static final VisitCost safetyCostFriday = VisitCost(
    id: 'cost-safety-fri',
    sessionId: sessionUpcomingFriday.id,
    category: 'safety',
    description: 'First-aid kit restock',
    amount: 10,
  );

  static List<VisitCost> get costs => [cleaningCostSunday, utilitiesCostSunday, safetyCostFriday];

  /// Booking 1 — confirmed, with a Horse Ride add-on (Friday session).
  static final VisitBooking bookingConfirmed = VisitBooking(
    id: 'booking-confirmed',
    visitorId: visitorNadine.id,
    sessionId: sessionUpcomingFriday.id,
    packageId: familyDayPackage.id,
    status: 'confirmed',
    adults: 2,
    children: 1,
    totalAmount: familyDayPackage.basePrice * 3 + horseRideActivity.price,
    depositAmount: 20,
    balanceDue: familyDayPackage.basePrice * 3 + horseRideActivity.price - 20,
    source: 'manual',
    activities: [VisitBookingActivity(activityId: horseRideActivity.id, scheduledAt: _at(_fri, '10:30'), quantity: 1, unitPrice: horseRideActivity.price)],
    createdAt: _now.subtract(const Duration(days: 3)),
    confirmedAt: _now.subtract(const Duration(days: 2)),
  );

  /// Booking 2 — draft, a school group awaiting confirmation (RULE-VIS-002:
  /// draft bookings never consume session capacity).
  static final VisitBooking bookingDraft = VisitBooking(
    id: 'booking-draft',
    visitorId: visitorSchool.id,
    sessionId: sessionUpcomingFriday.id,
    packageId: schoolVisitPackage.id,
    status: 'draft',
    adults: 2,
    children: 20,
    totalAmount: schoolVisitPackage.basePrice * 22,
    balanceDue: schoolVisitPackage.basePrice * 22,
    source: 'phone',
    notes: 'Awaiting deposit before confirming.',
    createdAt: _now.subtract(const Duration(days: 1)),
  );

  /// Booking 3 — cancelled (Saturday session).
  static final VisitBooking bookingCancelled = VisitBooking(
    id: 'booking-cancelled',
    visitorId: visitorKarim.id,
    sessionId: sessionUpcomingSaturday.id,
    packageId: familyDayPackage.id,
    status: 'cancelled',
    adults: 2,
    children: 0,
    totalAmount: familyDayPackage.basePrice * 2,
    balanceDue: familyDayPackage.basePrice * 2,
    source: 'walk_in',
    notes: 'Visitor rescheduled to next month.',
    createdAt: _now.subtract(const Duration(days: 5)),
    cancelledAt: _now.subtract(const Duration(days: 4)),
  );

  /// Booking 4 — checked in, a walk-in on the completed Sunday session.
  static final VisitBooking bookingCheckedIn = VisitBooking(
    id: 'booking-checked-in',
    visitorId: visitorKarim.id,
    sessionId: sessionCompletedSunday.id,
    packageId: familyDayPackage.id,
    status: 'checked_in',
    adults: 1,
    children: 0,
    totalAmount: familyDayPackage.basePrice,
    balanceDue: familyDayPackage.basePrice,
    source: 'walk_in',
    createdAt: _lastSun,
    confirmedAt: _lastSun,
    checkedInAt: _at(_lastSun, '10:05'),
  );

  /// Booking 5 — completed, with a Cheese Workshop add-on and a farm-shop
  /// retail sale of the real Mouneh Makdous stock (cross-module traceability
  /// — see `visitRetailSaleMakdous` below).
  static final VisitBooking bookingCompleted = VisitBooking(
    id: 'booking-completed',
    visitorId: visitorNadine.id,
    sessionId: sessionCompletedSunday.id,
    packageId: familyDayPackage.id,
    status: 'completed',
    adults: 2,
    children: 2,
    totalAmount: familyDayPackage.basePrice * 4 + cheeseWorkshopActivity.price * 4,
    depositAmount: 30,
    balanceDue: familyDayPackage.basePrice * 4 + cheeseWorkshopActivity.price * 4 - 30,
    source: 'manual',
    activities: [VisitBookingActivity(activityId: cheeseWorkshopActivity.id, scheduledAt: _at(_lastSun, '11:00'), quantity: 4, unitPrice: cheeseWorkshopActivity.price, status: 'completed')],
    createdAt: _lastSun.subtract(const Duration(days: 4)),
    confirmedAt: _lastSun.subtract(const Duration(days: 3)),
    checkedInAt: _at(_lastSun, '10:00'),
    completedAt: _at(_lastSun, '13:00'),
  );

  static List<VisitBooking> get bookings => [bookingConfirmed, bookingDraft, bookingCancelled, bookingCheckedIn, bookingCompleted];

  /// Cross-module traceability (RULE-VIS-006): this references the real
  /// Mouneh Makdous finished-goods stock row so the two modules stay
  /// linkable, but — like the rest of this file relative to
  /// `backend/app/visits/seed.py` — it is a display-only demo record and
  /// does not itself mutate `MounehDemoData`'s seeded stock counts.
  static final VisitRetailSale visitRetailSaleMakdous = VisitRetailSale(
    id: 'retail-sale-makdous-demo',
    bookingId: bookingCompleted.id,
    visitorId: visitorNadine.id,
    channel: 'farm_shop',
    totalAmount: 2 * MounehDemoData.makdous.targetPrice!,
    soldAt: _at(_lastSun, '12:30'),
  );

  static List<VisitRetailSale> get retailSales => [visitRetailSaleMakdous];

  static final VisitorFeedbackEntry feedbackCompleted = VisitorFeedbackEntry(
    id: 'feedback-completed',
    bookingId: bookingCompleted.id,
    rating: 5,
    comments: 'Wonderful day — the kids loved feeding the goats and the cheese workshop!',
    wouldReturn: true,
    submittedAt: _at(_lastSun, '13:15'),
  );

  static List<VisitorFeedbackEntry> get feedback => [feedbackCompleted];

  static final VisitIncident incidentAnimal = VisitIncident(
    id: 'incident-animal-sun',
    sessionId: sessionCompletedSunday.id,
    bookingId: bookingCheckedIn.id,
    incidentType: 'animal',
    severity: 'low',
    description: "A goat nipped at a child's jacket sleeve during the feeding activity; no injury.",
    actionTaken: 'Handler moved the group to a safer distance and reassured the family.',
    createdAt: _at(_lastSun, '10:40'),
  );

  static List<VisitIncident> get incidents => [incidentAnimal];
}
