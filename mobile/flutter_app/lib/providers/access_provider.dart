import 'package:flutter/foundation.dart';
import '../api/api_client.dart';
import '../domain/entities/access.dart';

/// The signed-in user's module responsibilities and permissions.
///
/// Loaded once at sign-in and read synchronously everywhere else, so a
/// screen can ask `access.canCreate(FarmModule.animals)` while building
/// without awaiting anything. The backend re-checks every request, so this
/// only decides what to *show*.
class AccessProvider extends ChangeNotifier {
  AccessProvider({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;
  UserAccess _access = UserAccess.empty;
  List<ModuleCatalogEntry> _catalog = [];
  bool loading = false;

  UserAccess get access => _access;
  List<ModuleCatalogEntry> get catalog => List.unmodifiable(_catalog);

  /// Modules this user holds — what the navigation is built from.
  ///
  /// This used to also require the farm to have licensed the module.
  /// Origami is one subscription covering every module now, so that half
  /// of the test could only ever pass — and worse, a tablet still holding
  /// a catalog it cached under the old model would keep hiding screens
  /// the farm had paid for until it managed to fetch a fresh one.
  List<ModuleCatalogEntry> get availableModules =>
      _catalog.where((m) => _access.canView(m.code)).toList();

  ModuleCatalogEntry? moduleByCode(String code) {
    for (final m in _catalog) {
      if (m.code == code) return m;
    }
    return null;
  }

  String moduleLabel(String code, String languageCode) => moduleByCode(code)?.label(languageCode) ?? code.replaceAll('_', ' ');

  /// True when this user holds the module. Nothing else: every farm has
  /// every module, including what used to be the Mouneh and Visits paid
  /// add-ons.
  bool isModuleAvailable(String code) => _access.canView(code);

  bool can(String moduleCode, String action) => _access.can(moduleCode, action);
  bool canView(String moduleCode) => _access.canView(moduleCode);
  bool canCreate(String moduleCode) => _access.canCreate(moduleCode);
  bool canEdit(String moduleCode) => _access.canEdit(moduleCode);
  bool canDelete(String moduleCode) => _access.canDelete(moduleCode);
  bool canAssign(String moduleCode) => _access.canAssign(moduleCode);
  bool get isFullAccess => _access.fullAccess;

  /// Feed approval: activating a recipe or program, a farm feed's first mix
  /// (which approves its recipe), releasing a held lot.
  bool get canApproveFeed => can(FarmModule.feedNutrition, PermissionAction.approve);

  /// Recording more feed than the stock on record is an approved exception
  /// — Feed or Inventory approval (backend api/deps.ensure_stock_override).
  bool get canOverrideFeedStock => canApproveFeed || can(FarmModule.inventory, PermissionAction.approve);

  // The farm's rule (v0.7.8): employees enter the day's milk and feedings;
  // buying feed, a numbered mix and corrections are the manager's. Someone
  // without the approval sends them as a request (ApprovalsProvider).

  /// Buys feed and records any delivery (Feed or Inventory approval).
  bool get canBuyFeed => canOverrideFeedStock;

  /// May ask the manager to buy feed and record an approved delivery.
  bool get canAskToBuyFeed => canCreate(FarmModule.feedNutrition) || canCreate(FarmModule.inventory);

  /// Records a numbered mix directly; anyone else with Feed create sends it.
  bool get canMixFeed => canApproveFeed;

  /// Changes the feed list, an animal's ration or a reservation.
  bool get canManageFeed => canApproveFeed;

  /// Counts the feed stock on inspection and corrects it to the count
  /// (v0.8.3, backend POST /feed-inventory/counts: Feed or Inventory approve).
  bool get canCountFeedStock => canOverrideFeedStock;

  /// Corrects a milk record directly; an employee asks for it.
  bool get canCorrectMilk => can(FarmModule.milkProduction, PermissionAction.approve);

  /// Corrects or undoes a feeding directly; an employee asks for it.
  bool get canCorrectFeeding => canApproveFeed;

  // Selling milk (v0.7.9): a commercial act — Sales or Finance, or the
  // milk module's approval (backend production.py).

  /// Sells milk from the tank and marks a sale paid.
  bool get canSellMilk => canCreate(FarmModule.sales) || canCreate(FarmModule.finance) || can(FarmModule.milkProduction, PermissionAction.approve);

  /// Cancels a milk sale recorded by mistake.
  bool get canCancelMilkSale =>
      can(FarmModule.milkProduction, PermissionAction.approve) || can(FarmModule.sales, PermissionAction.approve) || can(FarmModule.finance, PermissionAction.approve);

  /// Counts the tank and records milk spoiled or used outside a sale.
  bool get canAdjustMilkTank => can(FarmModule.milkProduction, PermissionAction.approve);

  // The milking routine (v0.8.1, backend production.py / finance.py).

  /// Hands a milking over: litres to the calves and to the collector (the
  /// collector and his price are the manager's settings).
  bool get canHandOverMilk => canCreate(FarmModule.milkProduction);

  /// Gives the cows their numbers in the milking queue (v0.8.2) — the
  /// manager: whoever may edit the animals or approve in Milk (backend
  /// PUT /animals/milking-queue).
  bool get canSetMilkingQueue => canEdit(FarmModule.animals) || can(FarmModule.milkProduction, PermissionAction.approve);

  /// Sets the milk collector, his price and what the second milking is called.
  bool get canSetMilkRoutine =>
      can(FarmModule.milkProduction, PermissionAction.approve) || can(FarmModule.finance, PermissionAction.approve) || can(FarmModule.settings, PermissionAction.configure);

  /// Records a buyer's payment for several sales (the collector's week).
  bool get canReceivePayment => canRecordSale || can(FarmModule.milkProduction, PermissionAction.approve);

  // Origami's financials (v0.8.0, backend finance.py).

  /// Records a sale of any product and marks a sale paid.
  bool get canRecordSale => canCreate(FarmModule.sales) || canCreate(FarmModule.finance);

  /// Cancels a sale recorded by mistake.
  bool get canCancelSale => can(FarmModule.sales, PermissionAction.approve) || can(FarmModule.finance, PermissionAction.approve);

  /// Cancels a sale in the Mouneh shop (its jars go back on the shelf).
  bool get canCancelMounehSale =>
      canCancelSale || can(FarmModule.mounehInventory, PermissionAction.approve) || can(FarmModule.mounehProduction, PermissionAction.approve);

  /// Records an expense or a bill and marks a bill paid.
  bool get canRecordExpense => canCreate(FarmModule.expenses) || canCreate(FarmModule.finance);

  /// Cancels an expense recorded by mistake.
  bool get canCancelExpense => can(FarmModule.expenses, PermissionAction.approve) || can(FarmModule.finance, PermissionAction.approve);

  /// Sets the USD / LBP exchange rate.
  bool get canSetExchangeRate => can(FarmModule.finance, PermissionAction.approve) || can(FarmModule.settings, PermissionAction.configure);

  bool get canSeeSales => [FarmModule.sales, FarmModule.finance].any((m) => can(m, PermissionAction.view));
  bool get canSeeExpenses => [FarmModule.expenses, FarmModule.finance].any((m) => can(m, PermissionAction.view));
  bool get canSeeProfitLoss => [FarmModule.finance, FarmModule.reports].any((m) => can(m, PermissionAction.view));

  /// Sees money: milk sales and revenue in the reports.
  bool get canSeeMoney => [FarmModule.reports, FarmModule.finance, FarmModule.sales].any((m) => can(m, PermissionAction.view));

  /// Reads the farm report [kind] (backend reports.py: Reports, or the
  /// report's own area).
  bool canReadReport(String kind) {
    final modules = switch (kind) {
      'milk' => [FarmModule.milkProduction],
      'feed' => [FarmModule.feedNutrition, FarmModule.inventory],
      'herd' => [FarmModule.animals, FarmModule.animalHealth],
      'finance' => [FarmModule.finance, FarmModule.sales],
      'sales' => [FarmModule.sales, FarmModule.finance],
      'stock' => [FarmModule.inventory, FarmModule.feedNutrition, FarmModule.mounehInventory, FarmModule.animalHealth, FarmModule.milkProduction],
      _ => const <String>[],
    };
    return [FarmModule.reports, ...modules].any((m) => can(m, PermissionAction.view));
  }

  /// A death is recorded with Animals *edit*; a sale, cull, slaughter or
  /// transfer is a business decision and needs Animals *approve* (backend
  /// livestock exit).
  bool canRecordExit(String exitType) =>
      exitType == 'dead' ? canEdit(FarmModule.animals) : can(FarmModule.animals, PermissionAction.approve);

  /// Changing the farm calendar (dry-off, milk peak, breeding wait).
  bool get canConfigureSettings => can(FarmModule.settings, PermissionAction.configure);

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      final results = await Future.wait([
        _api.get('/me/access'),
        _api.get('/modules/catalog'),
      ]);
      _access = UserAccess.fromJson(results[0] as Map<String, dynamic>);
      _catalog = (results[1] as List<dynamic>).map((e) => ModuleCatalogEntry.fromJson(e as Map<String, dynamic>)).toList();
    } finally {
      loading = false;
      notifyListeners();
    }
  }
}
