import 'package:flutter/foundation.dart';

/// Owns which shell tab is showing, so anything can drive navigation —
/// a notification, a priority card, a KPI tile — not just the nav rail.
///
/// [AppShell] renders `selectedIndex`; callers use [goToModule] and never
/// need to know what index a module ended up at for this particular user
/// (an Animals-only employee's tab 1 is a manager's tab 2).
class AppNavigator extends ChangeNotifier {
  int _selectedIndex = 0;

  /// Module code -> index, rebuilt whenever the visible tab set changes.
  Map<String, int> _moduleIndex = {};

  /// Set alongside a tab change so the destination screen can highlight or
  /// scroll to the record that sent the user there; cleared once consumed.
  String? _focusEntityType;
  String? _focusEntityId;

  int get selectedIndex => _selectedIndex;
  String? get focusEntityType => _focusEntityType;
  String? get focusEntityId => _focusEntityId;

  void registerTabs(Map<String, int> moduleIndex) {
    _moduleIndex = moduleIndex;
    if (_selectedIndex >= moduleIndex.length && moduleIndex.isNotEmpty) {
      _selectedIndex = 0;
    }
  }

  void select(int index) {
    if (index == _selectedIndex) return;
    _selectedIndex = index;
    _focusEntityType = null;
    _focusEntityId = null;
    notifyListeners();
  }

  /// Switches to whichever tab serves [moduleCode]. Returns false when the
  /// user has no tab for it — the caller then leaves them where they are
  /// rather than jumping somewhere unrelated.
  bool goToModule(String moduleCode, {String? entityType, String? entityId}) {
    final index = _moduleIndex[moduleCode];
    if (index == null) return false;
    _selectedIndex = index;
    _focusEntityType = entityType;
    _focusEntityId = entityId;
    notifyListeners();
    return true;
  }

  bool hasModule(String moduleCode) => _moduleIndex.containsKey(moduleCode);

  /// Called by a screen once it has acted on the focus request, so
  /// returning to that tab later does not re-trigger it.
  void clearFocus() {
    if (_focusEntityType == null && _focusEntityId == null) return;
    _focusEntityType = null;
    _focusEntityId = null;
    notifyListeners();
  }
}
