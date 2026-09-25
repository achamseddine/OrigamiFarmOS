import '../../domain/entities/animal.dart';
import '../../domain/entities/farm.dart';
import '../../domain/entities/field.dart';
import '../../domain/entities/finance.dart';
import '../../domain/entities/inventory.dart';
import '../../domain/entities/production.dart';
import '../../domain/entities/recommendation.dart';
import '../../domain/entities/task.dart';

DateTime _today() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

DateTime _at(int daysAgo, {int hour = 8, int minute = 0}) =>
    _today().subtract(Duration(days: daysAgo)).add(Duration(hours: hour, minutes: minute));

/// Origami Farms Option C demo dataset — matches the manager-demo narrative
/// in Branding kit/data/option-c-demo-data.json, expanded to cover every
/// field shown across all 10 Option C screens. This is the seed for
/// `data/local/demo_seed.dart` and the fallback read model until a screen is
/// wired to the SQLite repository layer.
class DemoData {
  DemoData._();

  static const farm = Farm(
    id: 'farm-origami',
    name: 'Origami Farms',
    region: 'Bekaa Valley',
    country: 'Lebanon',
    timezone: 'Asia/Beirut',
    defaultCurrency: 'USD',
  );

  static const managerName = 'Rami';

  // ---------------------------------------------------------------- Animals

  static final List<Animal> animals = [
    Animal(
      id: 'cow-744',
      tag: '744',
      name: 'Bella',
      species: AnimalSpecies.cow,
      breed: 'Holstein Friesian',
      sex: 'F',
      birthDate: DateTime.now().subtract(const Duration(days: 365 * 4 + 60)),
      status: AnimalHealthStatus.underTreatment,
      location: 'North Pasture — Group A',
      healthScore: 87,
      pregnant: true,
      pregnancyDays: 120,
      lactating: true,
      lactationCycle: 2,
      milkTodayL: 18.6,
      weightKg: 612,
      groupName: 'Dairy Herd',
    ),
    Animal(
      id: 'cow-214',
      tag: '214',
      name: 'Luna',
      species: AnimalSpecies.cow,
      breed: 'Holstein Friesian',
      sex: 'F',
      birthDate: DateTime.now().subtract(const Duration(days: 365 * 5)),
      status: AnimalHealthStatus.healthy,
      location: 'North Pasture',
      healthScore: 92,
      lactating: true,
      milkTodayL: 32.6,
      groupName: 'Dairy Herd',
    ),
    Animal(
      id: 'goat-189',
      tag: '189',
      name: 'Rasha',
      species: AnimalSpecies.goat,
      breed: 'Baladi',
      sex: 'F',
      birthDate: DateTime.now().subtract(const Duration(days: 365 * 3)),
      status: AnimalHealthStatus.underTreatment,
      location: 'North Pasture',
      healthScore: 58,
      groupName: 'Dairy Herd',
    ),
    Animal(
      id: 'goat-g032',
      tag: 'G-032',
      name: 'Mira',
      species: AnimalSpecies.goat,
      breed: 'Damascus',
      sex: 'F',
      birthDate: DateTime.now().subtract(const Duration(days: 365 * 2)),
      status: AnimalHealthStatus.underObservation,
      location: 'Hillside Paddock',
      healthScore: 76,
      milkTodayL: 2.4,
      groupName: 'Goat Group B',
    ),
    Animal(
      id: 'sheep-s045',
      tag: 'S-045',
      name: 'Daisy',
      species: AnimalSpecies.sheep,
      breed: 'Awassi',
      sex: 'F',
      birthDate: DateTime.now().subtract(const Duration(days: 365 * 2)),
      status: AnimalHealthStatus.healthy,
      location: 'Meadow Field',
      healthScore: 88,
      weightKg: 62,
      groupName: 'Sheep Group A',
    ),
    Animal(
      id: 'horse-h07',
      tag: 'H-07',
      name: 'Thunder',
      species: AnimalSpecies.horse,
      breed: 'Arabian',
      sex: 'M',
      birthDate: DateTime.now().subtract(const Duration(days: 365 * 6)),
      status: AnimalHealthStatus.healthy,
      location: 'Stables',
      healthScore: 90,
      weightKg: 480,
    ),
    Animal(
      id: 'hen-247',
      tag: 'L-247',
      name: 'Hen 247',
      species: AnimalSpecies.layerHen,
      breed: 'Lohmann Brown',
      sex: 'F',
      birthDate: DateTime.now().subtract(const Duration(days: 300)),
      status: AnimalHealthStatus.healthy,
      location: 'Poultry House 1',
      healthScore: 83,
      eggsToday: 1,
      groupName: 'Layer Flock',
    ),
    Animal(
      id: 'hen-183',
      tag: 'L-183',
      name: 'Hen 183',
      species: AnimalSpecies.layerHen,
      breed: 'Lohmann Brown',
      sex: 'F',
      birthDate: DateTime.now().subtract(const Duration(days: 340)),
      status: AnimalHealthStatus.underTreatment,
      location: 'Poultry House 1',
      healthScore: 45,
      groupName: 'Layer Flock',
    ),
    Animal(
      id: 'duck-012',
      tag: 'D-012',
      name: 'Duck 12',
      species: AnimalSpecies.duck,
      breed: 'Pekin',
      sex: 'F',
      birthDate: DateTime.now().subtract(const Duration(days: 220)),
      status: AnimalHealthStatus.underObservation,
      location: 'Pond Area',
      healthScore: 78,
      weightKg: 2.1,
      groupName: 'Duck Flock',
    ),
    Animal(
      id: 'goat-willow',
      tag: 'S-118',
      name: 'Willow',
      species: AnimalSpecies.goat,
      breed: 'Saanen',
      sex: 'F',
      birthDate: DateTime.now().subtract(const Duration(days: 365 * 3)),
      status: AnimalHealthStatus.underTreatment,
      location: 'Hillside Paddock',
      healthScore: 64,
      lactating: true,
      underWithdrawalUntil: _at(-2, hour: 0),
      withdrawalReason: 'Medication',
      groupName: 'Goat Group B',
    ),
    Animal(
      id: 'cow-clover',
      tag: '381',
      name: 'Clover',
      species: AnimalSpecies.cow,
      breed: 'Holstein',
      sex: 'F',
      birthDate: DateTime.now().subtract(const Duration(days: 365 * 3)),
      status: AnimalHealthStatus.healthy,
      location: 'North Pasture',
      healthScore: 91,
      lactating: true,
      milkTodayL: 23.7,
      groupName: 'Dairy Herd',
    ),
    Animal(
      id: 'goat-gigi',
      tag: 'G-091',
      name: 'Gigi',
      species: AnimalSpecies.goat,
      breed: 'Saanen',
      sex: 'F',
      birthDate: DateTime.now().subtract(const Duration(days: 365 * 2)),
      status: AnimalHealthStatus.healthy,
      location: 'Hillside Paddock',
      healthScore: 89,
      lactating: true,
      milkTodayL: 19.3,
      groupName: 'Goat Group B',
    ),
  ];

  static final animalSummary = <String, int>{
    'total': 592,
    'healthy': 488,
    'underObservation': 48,
    'underTreatment': 27,
    'pregnant': 73,
    'lactating': 196,
  };

  static final herdGroups = <Map<String, Object>>[
    {'name': 'Dairy Herd', 'species': 'Cow', 'count': 78, 'healthy': 64, 'attention': 14},
    {'name': 'Sheep Group A', 'species': 'Sheep', 'count': 124, 'healthy': 110, 'attention': 14},
    {'name': 'Goat Group B', 'species': 'Goat', 'count': 86, 'healthy': 72, 'attention': 14},
    {'name': 'Layer Flock', 'species': 'Poultry', 'count': 248, 'healthy': 226, 'attention': 22},
    {'name': 'Duck Flock', 'species': 'Poultry', 'count': 56, 'healthy': 50, 'attention': 6},
  ];

  static final Flock layerFlock = Flock(
    id: 'flock-layer',
    name: 'Layer Flock',
    species: AnimalSpecies.layerHen,
    count: 2450,
    location: 'Poultry House 1–3',
    status: AnimalHealthStatus.healthy,
    eggsToday: 4212,
    vsLastWeekPct: 7.3,
  );

  static final Flock duckFlock = Flock(
    id: 'flock-duck',
    name: 'Duck Flock',
    species: AnimalSpecies.duck,
    count: 680,
    location: 'Pond Area',
    status: AnimalHealthStatus.underObservation,
    eggsToday: 1128,
    vsLastWeekPct: -22.0,
  );

  static final Flock turkeyFlock = Flock(
    id: 'flock-turkey',
    name: 'Turkey Flock',
    species: AnimalSpecies.turkey,
    count: 120,
    location: 'Barn C',
    status: AnimalHealthStatus.healthy,
    eggsToday: 502,
    vsLastWeekPct: 3.1,
  );

  // ------------------------------------------------------------------ Feed

  static final List<InventoryItem> feedInventory = [
    InventoryItem(
      id: 'feed-dairy-mix',
      name: 'Dairy Mix',
      category: 'Dairy',
      unit: 'kg',
      currentQty: 3250,
      reorderLevel: 2000,
      supplier: 'Al Mashreq',
      lastPurchase: _at(18),
      unitCost: 0.42,
    ),
    InventoryItem(
      id: 'feed-alfalfa',
      name: 'Alfalfa Hay',
      category: 'Dairy',
      unit: 'kg',
      currentQty: 4800,
      reorderLevel: 3000,
      supplier: 'Bekaa Hay Co.',
      lastPurchase: _at(25),
      unitCost: 0.31,
    ),
    InventoryItem(
      id: 'feed-corn-silage',
      name: 'Corn Silage',
      category: 'Dairy',
      unit: 'kg',
      currentQty: 2200,
      reorderLevel: 2500,
      supplier: 'Farm Harvest',
      lastPurchase: _at(22),
      unitCost: 0.18,
    ),
    InventoryItem(
      id: 'feed-layer',
      name: 'Layer Feed',
      category: 'Poultry',
      unit: 'kg',
      currentQty: 1150,
      reorderLevel: 1500,
      supplier: 'Al Mashreq',
      lastPurchase: _at(20),
      unitCost: 0.39,
    ),
    InventoryItem(
      id: 'feed-goat-mix',
      name: 'Goat Mix',
      category: 'Goats',
      unit: 'kg',
      currentQty: 900,
      reorderLevel: 800,
      supplier: 'Green Feed Co.',
      lastPurchase: _at(24),
      unitCost: 0.44,
    ),
    InventoryItem(
      id: 'feed-minerals',
      name: 'Minerals',
      category: 'Minerals',
      unit: 'kg',
      currentQty: 320,
      reorderLevel: 300,
      supplier: 'NutriPlus',
      lastPurchase: _at(29),
      unitCost: 1.10,
    ),
    InventoryItem(
      id: 'feed-medicine',
      name: 'Medicine',
      category: 'Medicine',
      unit: 'items',
      currentQty: 14,
      reorderLevel: 10,
      supplier: 'VetCare',
      lastPurchase: _at(34),
      unitCost: 12.5,
    ),
  ];

  static const feedingPlan = [
    FeedingPlanLine(groupLabel: 'Dairy Cows (78)', subLabel: 'Milking & Dry Cows', quantityKg: 1420, perHeadKg: 5.6),
    FeedingPlanLine(groupLabel: 'Heifers (32)', subLabel: '6–18 months', quantityKg: 380, perHeadKg: 11.9),
    FeedingPlanLine(groupLabel: 'Goats (312)', subLabel: 'All goats', quantityKg: 280, perHeadKg: 0.9),
    FeedingPlanLine(groupLabel: 'Layers (592)', subLabel: 'Laying Hens', quantityKg: 310, perHeadKg: 0.52),
  ];

  static const feedConsumptionTrendMT = [0.55, 0.62, 0.68, 0.74, 0.86, 0.98, 1.12];
  static const feedConsumptionTrendLastMonthMT = [0.42, 0.48, 0.55, 0.58, 0.63, 0.72, 0.80];

  // ------------------------------------------------------------------ Milk

  static const milkLast7DaysMorning = [280.0, 292.0, 288.0, 301.0, 296.0, 305.0, 312.0];
  static const milkLast7DaysEvening = [252.0, 248.0, 260.0, 258.0, 264.0, 270.0, 280.0];
  static const milkLast7DaysLabels = ['D-6', 'D-5', 'D-4', 'D-3', 'D-2', 'Yesterday', 'Today'];

  static final topMilkProducers = <Map<String, Object>>[
    {'name': 'Luna', 'breed': 'Holstein', 'liters': 32.6},
    {'name': 'Bella', 'breed': 'Holstein', 'liters': 28.1},
    {'name': 'Daisy', 'breed': 'Jersey', 'liters': 25.4},
    {'name': 'Clover', 'breed': 'Holstein', 'liters': 23.7},
    {'name': 'Gigi', 'breed': 'Saanen', 'liters': 19.3},
  ];

  // ------------------------------------------------------------------ Eggs

  static const eggProductionTrendThisWeek = [4800.0, 5100.0, 5000.0, 5300.0, 5400.0, 5600.0, 5842.0];
  static const eggProductionTrendLastWeek = [4500.0, 4700.0, 4750.0, 4900.0, 5000.0, 5150.0, 5300.0];

  // -------------------------------------------------------------- Produce

  static final List<Field> fields = [
    Field(
      id: 'field-2',
      name: 'Field 2 — Tomatoes',
      cropType: 'Tomatoes',
      stage: FieldStage.ripening,
      estYieldKg: 420,
      nextHarvest: _today().add(const Duration(days: 1)),
      healthLabel: 'Good',
    ),
    Field(
      id: 'field-3',
      name: 'Field 3 — Zucchini',
      cropType: 'Zucchini',
      stage: FieldStage.flowering,
      estYieldKg: 310,
      nextHarvest: _today().add(const Duration(days: 3)),
      healthLabel: 'Good',
    ),
    Field(
      id: 'field-4',
      name: 'Field 4 — Cucumbers',
      cropType: 'Cucumbers',
      stage: FieldStage.growing,
      estYieldKg: 280,
      nextHarvest: _today().add(const Duration(days: 5)),
      healthLabel: 'Good',
    ),
    Field(
      id: 'field-herb',
      name: 'Herb Garden — Basil',
      cropType: 'Basil',
      stage: FieldStage.mature,
      estYieldKg: 65,
      nextHarvest: _today(),
      healthLabel: 'Excellent',
    ),
    Field(
      id: 'field-orchard',
      name: 'Orchard — Oranges',
      cropType: 'Oranges',
      stage: FieldStage.developing,
      estYieldKg: 1200,
      nextHarvest: _today().add(const Duration(days: 28)),
      healthLabel: 'Good',
    ),
  ];

  static const weeklyYieldKg = [820.0, 940.0, 1090.0, 1285.0, 1400.0];
  static const weeklyYieldLabels = ['4 wks ago', '3 wks ago', '2 wks ago', 'Last week', 'This week'];

  static final produceInventory = <Map<String, Object>>[
    {'name': 'Tomatoes', 'qty': 320, 'unit': 'kg'},
    {'name': 'Zucchini', 'qty': 210, 'unit': 'kg'},
    {'name': 'Cucumbers', 'qty': 180, 'unit': 'kg'},
    {'name': 'Basil', 'qty': 45, 'unit': 'kg'},
  ];

  static final readyForSale = <Map<String, Object>>[
    {'name': 'Tomatoes', 'qty': 120, 'unit': 'kg'},
    {'name': 'Zucchini', 'qty': 90, 'unit': 'kg'},
    {'name': 'Cucumbers', 'qty': 70, 'unit': 'kg'},
    {'name': 'Basil', 'qty': 20, 'unit': 'kg'},
  ];

  // --------------------------------------------------------------- Finance

  static final List<Sale> salesToday = [
    Sale(id: 's1', productType: 'milk', productLabel: 'Milk', quantity: 340, unit: 'L', amountUsd: 4250, paymentStatus: PaymentStatus.paid, soldAt: _at(0, hour: 9)),
    Sale(id: 's2', productType: 'eggs', productLabel: 'Eggs', quantity: 285, unit: 'dozen', amountUsd: 2380, paymentStatus: PaymentStatus.paid, soldAt: _at(0, hour: 9, minute: 30)),
    Sale(id: 's3', productType: 'produce', productLabel: 'Produce', quantity: 260, unit: 'kg', amountUsd: 3120, paymentStatus: PaymentStatus.pending, soldAt: _at(0, hour: 10)),
    Sale(id: 's4', productType: 'animals', productLabel: 'Animals', quantity: 1, unit: 'head', amountUsd: 2150, paymentStatus: PaymentStatus.paid, soldAt: _at(0, hour: 11)),
    Sale(id: 's5', productType: 'farm_products', productLabel: 'Farm Products', quantity: 40, unit: 'units', amountUsd: 945, paymentStatus: PaymentStatus.partial, soldAt: _at(0, hour: 12)),
  ];

  static final List<Expense> expensesToday = [
    Expense(id: 'e1', category: 'feed', amountUsd: 1680, incurredAt: _at(0, hour: 8)),
    Expense(id: 'e2', category: 'medicine', amountUsd: 720, incurredAt: _at(0, hour: 9)),
    Expense(id: 'e3', category: 'labor', amountUsd: 1150, incurredAt: _at(0, hour: 10)),
    Expense(id: 'e4', category: 'fuel', amountUsd: 420, incurredAt: _at(0, hour: 11)),
    Expense(id: 'e5', category: 'other', amountUsd: 260, incurredAt: _at(0, hour: 13)),
  ];

  static const profitTrend7Days = [3200.0, 5100.0, 6600.0, 6100.0, 7300.0, 7900.0, 8615.0];
  static const profitTrend7DaysLabels = ['D-6', 'D-5', 'D-4', 'D-3', 'D-2', 'Yesterday', 'Today'];

  static final topSellingProducts = <Map<String, Object>>[
    {'name': 'Fresh Milk (1L)', 'amount': 2850, 'pct': 22.2},
    {'name': 'Farm Eggs (Dozen)', 'amount': 2380, 'pct': 18.5},
    {'name': 'Zucchini', 'amount': 1240, 'pct': 9.6},
  ];

  // ------------------------------------------------------------ Tasks

  static final List<FarmTask> todaysTasks = [
    FarmTask(id: 't1', title: 'Inspect Cow 744', category: 'Health check', dueAt: _at(0, hour: 9), priority: TaskPriority.high, sourceType: 'recommendation', sourceId: 'rec-health-744'),
    FarmTask(id: 't2', title: 'Reorder dairy mix', category: 'Low stock alert', dueAt: _at(0, hour: 10, minute: 30), priority: TaskPriority.medium, sourceType: 'recommendation', sourceId: 'rec-feed-dairy-mix'),
    FarmTask(id: 't3', title: 'Collect duck eggs', category: 'Main house', dueAt: _at(0, hour: 11)),
    FarmTask(id: 't4', title: 'Harvest tomatoes in Field 2', category: 'Estimated 80 kg', dueAt: _at(0, hour: 15), sourceType: 'recommendation', sourceId: 'rec-harvest-field2'),
  ];

  // ---------------------------------------------------------- Recommendations

  static final List<Recommendation> recommendations = [
    Recommendation(
      id: 'rec-health-744',
      category: RecommendationCategory.health,
      priority: RecommendationPriority.high,
      title: 'Mastitis Risk Detected',
      entityLabel: 'Cow 744',
      confidence: 0.87,
      rationale:
          "Bella's milk yield has dropped 18% over the last 3 days while feed intake dropped 12% and "
          'body temperature is elevated. This pattern, combined with 2 prior mastitis cases, indicates '
          'developing udder inflammation.',
      suggestedAction: 'Isolate Cow 744 and start mastitis protocol. Recheck in 12 hours. Notify '
          'veterinarian if fever persists.',
      evidence: const [
        RecommendationEvidence(label: 'Milk Yield', value: '↓18% vs last 3 days', trendDown: true),
        RecommendationEvidence(label: 'Feed Intake', value: '↓12% vs last 3 days', trendDown: true),
        RecommendationEvidence(label: 'Temperature', value: '39.6°C — Elevated', trendDown: false),
        RecommendationEvidence(label: 'History', value: 'Mastitis — 2 prior cases', trendDown: false),
      ],
      generatedAt: _at(0, hour: 6),
      ruleId: 'RULE-HEALTH-RISK',
    ),
    Recommendation(
      id: 'rec-health-goat-219',
      category: RecommendationCategory.health,
      priority: RecommendationPriority.medium,
      title: 'Repeated Low Appetite',
      entityLabel: 'Goat 219',
      confidence: 0.62,
      rationale: 'Goat 219 has been observed with reduced appetite on 3 of the last 4 days. No single '
          'observation is conclusive, but the repetition raises the priority for a manual check.',
      suggestedAction: 'Assign a worker to check feed access and general condition today.',
      evidence: const [
        RecommendationEvidence(label: 'Observations', value: '3 of last 4 days — reduced appetite'),
        RecommendationEvidence(label: 'Quality', value: 'Level C — human observed'),
      ],
      generatedAt: _at(0, hour: 5),
      ruleId: 'RULE-HEALTH-RISK',
    ),
    Recommendation(
      id: 'rec-feed-dairy-mix',
      category: RecommendationCategory.feed,
      priority: RecommendationPriority.medium,
      title: 'Low feed: Dairy Mix',
      entityLabel: 'Dairy Mix',
      confidence: 0.95,
      rationale: 'Dairy Mix stock (3.25 t) covers roughly 6 more days at current consumption, and the '
          'next purchase lead time from Al Mashreq is typically 3–4 days.',
      suggestedAction: 'Place a reorder for at least 2,000 kg of Dairy Mix this week.',
      evidence: const [
        RecommendationEvidence(label: 'Current stock', value: '3,250 kg'),
        RecommendationEvidence(label: 'Reorder level', value: '2,000 kg'),
        RecommendationEvidence(label: 'Days remaining', value: '~6 days', trendDown: true),
      ],
      generatedAt: _at(0, hour: 6),
      ruleId: 'RULE-LOW-FEED',
    ),
    Recommendation(
      id: 'rec-egg-duck',
      category: RecommendationCategory.egg,
      priority: RecommendationPriority.medium,
      title: 'Duck flock production down 22%',
      entityLabel: 'Duck Flock',
      confidence: 0.74,
      rationale: 'Duck egg output is down 22% versus last week, which exceeds the 20% investigation '
          'threshold. No corresponding feed-shortage or health alert has been logged yet for this flock.',
      suggestedAction: 'Investigate feed intake and water temperature in the pond area today.',
      evidence: const [
        RecommendationEvidence(label: 'Production', value: '1,128 vs 1,446 last week', trendDown: true),
        RecommendationEvidence(label: 'Threshold', value: '>20% drop triggers review'),
      ],
      generatedAt: _at(0, hour: 6),
      ruleId: 'RULE-EGG-DROP',
    ),
    Recommendation(
      id: 'rec-harvest-field2',
      category: RecommendationCategory.harvest,
      priority: RecommendationPriority.low,
      title: 'Zucchini ready in 2 days',
      entityLabel: 'Field 2 — Tomatoes',
      confidence: 0.9,
      rationale: 'Field 2 tomatoes are in the ripening stage with an estimated harvest date within 48 '
          'hours based on planting date and growth-stage tracking.',
      suggestedAction: 'Schedule harvest crew for Field 2, ~120 kg expected across 2 beds.',
      evidence: const [
        RecommendationEvidence(label: 'Stage', value: 'Ripening'),
        RecommendationEvidence(label: 'Expected harvest', value: 'Within 48 hours'),
      ],
      generatedAt: _at(0, hour: 6),
      ruleId: 'RULE-HARVEST-DUE',
    ),
    Recommendation(
      id: 'rec-vaccination',
      category: RecommendationCategory.health,
      priority: RecommendationPriority.low,
      title: 'Vaccination Due',
      entityLabel: '12 animals',
      confidence: 0.98,
      rationale: '12 animals are due for their scheduled vaccination this week based on the herd health '
          'calendar.',
      suggestedAction: 'Coordinate with the veterinarian to schedule a vaccination round.',
      evidence: const [RecommendationEvidence(label: 'Animals due', value: '12')],
      generatedAt: _at(1, hour: 8),
      ruleId: 'RULE-VACCINATION-DUE',
    ),
    Recommendation(
      id: 'rec-flock-mortality',
      category: RecommendationCategory.health,
      priority: RecommendationPriority.medium,
      title: 'Elevated Mortality Risk',
      entityLabel: 'Flock Barn A',
      confidence: 0.58,
      rationale: 'Barn A has logged 2 more mortalities than its 30-day average this week, which is above '
          'the normal variation band.',
      suggestedAction: 'Have a worker inspect ventilation and water lines in Barn A today.',
      evidence: const [
        RecommendationEvidence(label: 'Mortality', value: '+2 vs 30-day average', trendDown: false),
      ],
      generatedAt: _at(1, hour: 7),
      ruleId: 'RULE-HEALTH-RISK',
    ),
    Recommendation(
      id: 'rec-finance-feed-cost',
      category: RecommendationCategory.finance,
      priority: RecommendationPriority.info,
      title: 'Feed cost share is high',
      entityLabel: 'Feed expenses',
      confidence: 0.8,
      rationale: 'Feed now represents 39.7% of today\'s total expenses, above the 35% attention '
          'threshold used for supplier/usage review.',
      suggestedAction: 'Review feed usage per group and compare current supplier pricing.',
      evidence: const [
        RecommendationEvidence(label: 'Feed share of expenses', value: '39.7%', trendDown: false),
      ],
      generatedAt: _at(0, hour: 6),
      ruleId: 'RULE-FEED-COST-INSIGHT',
    ),
  ];

  static Recommendation get featuredRecommendation =>
      recommendations.firstWhere((r) => r.id == 'rec-health-744');

  static const businessInsights = [
    'Feed remains the highest cost category, representing 39.7% of total expenses. Consider '
        'optimizing feed usage or suppliers.',
    'Egg sales up 6% this week compared to last week. Great performance — keep leveraging this '
        'momentum.',
    'Cash collection rate is 72% today. Focus on collecting pending payments to improve cash flow.',
  ];

  static const weeklyWeather = [
    {'day': 'Wed', 'hi': 20, 'lo': 11, 'condition': 'sun'},
    {'day': 'Thu', 'hi': 21, 'lo': 12, 'condition': 'sun'},
    {'day': 'Fri', 'hi': 19, 'lo': 10, 'condition': 'rain'},
    {'day': 'Sat', 'hi': 18, 'lo': 9, 'condition': 'cloud'},
  ];

  static const todaysTimeline = [
    {'time': '6 AM', 'label': 'Milking', 'icon': 'milkBottle'},
    {'time': '9 AM', 'label': 'Health Checks', 'icon': 'stethoscope'},
    {'time': '11 AM', 'label': 'Egg Collection', 'icon': 'egg'},
    {'time': '3 PM', 'label': 'Field Work', 'icon': 'leaf'},
    {'time': '5 PM', 'label': 'Feeding', 'icon': 'feedBag'},
    {'time': '8 PM', 'label': 'Evening Rounds', 'icon': 'sun'},
  ];
}
