import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:farmos/api/api_client.dart';
import 'package:farmos/features/animals/add_animal_form.dart';
import 'package:farmos/features/animals/animal_quick_actions.dart';
import 'package:farmos/features/feed/feeding_event_dialog.dart';
import 'package:farmos/features/feed/purchase_and_mix_dialogs.dart';
import 'package:farmos/providers/animals_provider.dart';

import '../support/snapshot_farm.dart';

/// The same fact entered twice, and who may approve an exception — the
/// tablet side of backend app/core/duplicates.py and the approval levels
/// (architecture/API-STANDARDS.md "Duplicate entries and approvals").
void main() {
  const bellaMorning = "Bella's morning milk is already recorded for this day (18.6 L).";

  /// A worker with the animal department's starting grants: view, create
  /// and edit — no approve, no configure.
  const workerAccess = {
    'user_id': 'user-worker-1',
    'role': 'worker',
    'full_access': false,
    'modules': {
      'animals': {'view': true, 'create': true, 'edit': true},
      'feed_nutrition': {'view': true, 'create': true, 'edit': true},
      'inventory': {'view': true, 'create': true, 'edit': true},
      'milk_production': {'view': true, 'create': true, 'edit': true},
      'settings': {'view': true, 'create': true, 'edit': true},
    },
  };

  Future<SnapshotFarm> open(WidgetTester tester, void Function(BuildContext) onTap, {bool worker = false}) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    if (worker) farm.api.snapshot['GET /me/access'] = workerAccess;
    await tester.pumpWidget(farm.app(Scaffold(
      body: Builder(builder: (context) => Center(child: TextButton(onPressed: () => onTap(context), child: const Text('open')))),
    )));
    await settle(tester);
    return farm;
  }

  group('a possible duplicate', () {
    testWidgets('is asked; "No" records nothing, "Yes" records it confirmed', (tester) async {
      late SnapshotFarm farm;
      farm = await open(tester, (c) => showMilkDialog(c, c.read<AnimalsProvider>().find('cow-744')!));
      farm.api.possibleDuplicates['/production/milk'] = bellaMorning;
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, '12');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settle(tester);

      expect(find.text('Already recorded?'), findsOneWidget);
      expect(find.text(bellaMorning), findsOneWidget, reason: 'the server says what is already there');
      await tester.tap(find.text("No, don't record it"));
      await settle(tester);
      expect(farm.api.writes.where((w) => w.$1 == 'POST'), isEmpty, reason: 'nothing recorded twice');
      expect(find.textContaining(kPossibleDuplicate), findsOneWidget, reason: 'the form keeps the reason');

      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settle(tester);
      await tester.tap(find.text('Yes, record it again'));
      await settle(tester);
      final sent = farm.api.writes.lastWhere((w) => w.$1 == 'POST' && w.$2 == '/production/milk').$3! as Map;
      expect(sent['confirm_duplicate'], isTrue);
      expect(sent['liters'], 12);
    });
  });

  group('approval levels', () {
    testWidgets('a worker is not offered the stock override on a feeding', (tester) async {
      await open(tester, (c) => showFeedingEventDialog(c, subjectType: 'animal', subjectId: 'cow-744', subjectName: 'Bella'), worker: true);
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(2), '99999');
      await tester.pump();
      expect(find.text('Not enough stock recorded'), findsOneWidget);
      expect(find.text('Stock not entered yet — record anyway'), findsNothing);
      expect(find.textContaining('needs Feed or Inventory approval'), findsOneWidget);
    });

    testWidgets('a manager is offered it', (tester) async {
      await open(tester, (c) => showFeedingEventDialog(c, subjectType: 'animal', subjectId: 'cow-744', subjectName: 'Bella'));
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(2), '99999');
      await tester.pump();
      expect(find.text('Stock not entered yet — record anyway'), findsOneWidget);
    });

    testWidgets("a worker cannot make a feed's first mix (it would approve its recipe)", (tester) async {
      await open(tester, (c) => showRecordMixDialog(c, productId: 'fp-corn-silage'), worker: true);
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.byKey(const ValueKey('mix-needs-approval')), findsOneWidget);
      expect(find.textContaining('Corn Silage has no approved recipe yet'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save the mix')).onPressed, isNull);
    });

    testWidgets('a feed with an approved recipe is mixed by the worker', (tester) async {
      await open(tester, (c) => showRecordMixDialog(c, productId: 'fp-dairy-mix'), worker: true);
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.byKey(const ValueKey('mix-needs-approval')), findsNothing);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save the mix')).onPressed, isNotNull);
    });

    testWidgets('a worker records a death but not a sale', (tester) async {
      await open(tester, (c) => showAnimalForm(c, animal: c.read<AnimalsProvider>().find('cow-744')!), worker: true);
      await tester.tap(find.text('open'));
      await settle(tester);
      final sold = find.widgetWithText(ChoiceChip, 'Sold');
      await tester.ensureVisible(sold);
      expect(tester.widget<ChoiceChip>(sold).onSelected, isNull);
      expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Died')).onSelected, isNotNull);
      expect(find.textContaining('needs Animals approval'), findsOneWidget);
    });
  });

  group('milk and the lactation record', () {
    testWidgets('a cow not marked as being milked is started first, then her milk record opens', (tester) async {
      late SnapshotFarm farm;
      // Mira (goat-g032) is on the farm but not in milk.
      farm = await open(tester, (c) => showMilkDialog(c, c.read<AnimalsProvider>().find('goat-g032')!));
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.textContaining('Mira is not marked as being milked yet'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Quantity (liters)'), findsNothing, reason: 'no milk field before she is in milk');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settle(tester);
      expect(farm.api.writes.any((w) => w.$1 == 'POST' && w.$2 == '/animals/goat-g032/lactations'), isTrue);
      expect(find.textContaining('Mira'), findsWidgets, reason: 'the milk record opened after the start');
      expect(farm.api.writes.where((w) => w.$2 == '/production/milk'), isEmpty);
    });
  });

  group('server refusals are readable', () {
    test('a field-by-field validation refusal becomes sentences', () {
      final text = readableValidation([
        {
          'type': 'value_error',
          'loc': ['body', 'liters'],
          'msg': 'Value error, 185 L is more than one animal gives in one milking — check the amount',
        },
        {
          'type': 'greater_than_equal',
          'loc': ['body', 'unit_cost'],
          'msg': 'Input should be greater than or equal to 0',
        },
      ]);
      expect(text, 'Liters: 185 L is more than one animal gives in one milking — check the amount\nUnit cost: Input should be greater than or equal to 0');
      expect(text, isNot(contains('value_error')));
    });
  });

  group('the API client', () {
    tearDown(() => ApiClient.confirmPossibleDuplicate = null);

    test('resends one refused write confirmed when the person says so', () async {
      final api = _Refusing();
      ApiClient.confirmPossibleDuplicate = (detail) async {
        expect(detail, bellaMorning);
        return true;
      };
      final result = await api.write(() => api.post('/production/milk', body: {'animal_id': 'cow-744', 'liters': 3}));
      expect(result.success, isTrue);
      expect(api.sent, hasLength(2));
      expect((api.sent.last.$2 as Map)['confirm_duplicate'], isTrue);
      expect(api.sent.first.$3, api.sent.last.$3, reason: 'one logical write, one idempotency key');
    });

    test('leaves it unrecorded, with the reason, when the person says no', () async {
      final api = _Refusing();
      ApiClient.confirmPossibleDuplicate = (_) async => false;
      final result = await api.write(() => api.post('/production/milk', body: {'animal_id': 'cow-744', 'liters': 3}));
      expect(result.success, isFalse);
      expect(result.isPossibleDuplicate, isTrue);
      expect(result.statusCode, 409);
      expect(api.sent, hasLength(1));
    });
  });
}

/// Refuses the first unconfirmed write as a possible duplicate.
class _Refusing extends ApiClient {
  _Refusing() : super(baseUrl: 'http://refusing.invalid');
  final List<(String, Object?, String?)> sent = [];

  @override
  Future<dynamic> send(String method, String path, {Object? body, Map<String, dynamic>? query, String? idempotencyKey}) async {
    sent.add((path, body, idempotencyKey));
    if (body is Map && body['confirm_duplicate'] != true) {
      throw ApiException(409, "$kPossibleDuplicate Bella's morning milk is already recorded for this day (18.6 L).");
    }
    return {'id': 'm-1', ...?(body as Map?)?.cast<String, dynamic>()};
  }
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
