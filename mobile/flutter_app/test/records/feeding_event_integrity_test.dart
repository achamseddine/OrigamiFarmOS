import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmos/api/api_client.dart';
import 'package:farmos/domain/entities/feeding.dart';
import 'package:farmos/domain/entities/feeding_overlap.dart';
import 'package:farmos/features/animals/animal_quick_entry_screen.dart';
import 'package:farmos/features/feed/feeding_event_dialog.dart';

import '../support/snapshot_farm.dart';

/// Feeding event integrity (v0.8.7, audit I-7 / I-12), the same on the
/// tablet and the web:
///   - a head fed with her group and on her own in the same round, the same
///     feed, is asked about in the person's language — *Record as
///     additional feeding* sends `confirm_additional_feeding` with the
///     reason given (required), *Don't
///     record* sends nothing; a supplement, another feed, a refusal or a
///     partial group feeding is not asked; it works from what the device
///     holds, so offline too; what only the server can see is asked by the
///     same question, from the field names its 409 gives;
///   - what was eaten or left over cannot be more than what was given (the
///     server's `more_than_given`, shown in the person's language).
void main() {
  DailyPlan plan({List<String> covered = const ['cow-744', 'cow-214', 'cow-clover'], int heads = 3}) => DailyPlan.fromJson({
        'date': '2026-11-26',
        'lines': [
          {'subject_type': 'group', 'subject_id': 'grp-dairy-herd', 'name': 'Dairy Herd', 'species': 'cow', 'head_count': heads,
           'member_count': 3, 'covered_animal_ids': covered, 'daily_targets': <dynamic>[], 'warnings': <dynamic>[]},
          {'subject_type': 'animal', 'subject_id': 'cow-744', 'name': 'Bella', 'species': 'cow', 'head_count': 1, 'basis': 'supplement_only',
           'daily_targets': [{'feed_product_id': 'fp-dairy-concentrate', 'unit': 'kg', 'daily_total': 2}], 'warnings': <dynamic>[]},
        ],
        'totals': <dynamic>[],
      });

  FeedingEvent event(String id, String type, String subject, DateTime at, List<String> feeds, {String kind = 'delivered', int? heads, String status = 'recorded'}) =>
      FeedingEvent.fromJson({
        'id': id, 'subject_type': type, 'subject_id': subject, 'occurred_at': at.toIso8601String(), 'event_type': kind, 'status': status,
        'head_count': ?heads,
        'components': [for (final f in feeds) {'id': '$id-$f', 'feed_product_id': f, 'quantity_offered': 10, 'unit': 'kg'}],
      });

  Map<String, dynamic> body(String type, String subject, List<String> feeds, {String kind = 'offered', DateTime? at, int? heads, bool confirm = false}) => {
        'subject_type': type, 'subject_id': subject, 'event_type': kind,
        if (at != null) 'occurred_at': at.toIso8601String(),
        'head_count': ?heads,
        if (confirm) 'confirm_additional_feeding': true,
        'components': [for (final f in feeds) {'feed_product_id': f, 'quantity_offered': 10}],
      };

  group('I-12: one round is not counted twice', () {
    final herd0600 = event('herd', 'group', 'grp-dairy-herd', DateTime.utc(2026, 11, 26, 4, 0), ['fp-dairy-mix', 'fp-dairy-concentrate'], heads: 3);

    test('a cow fed with her group at 06:00 and on her own at 06:05 is asked', () {
      final o = findFeedingOverlap(body('animal', 'cow-214', ['fp-dairy-mix'], at: DateTime.utc(2026, 11, 26, 4, 5)), plan: plan(), events: [herd0600]);
      expect(o, isNotNull);
      expect((o!.kind, o.groupName, o.other.id, o.heads), (FeedingOverlapKind.animalAfterGroup, 'Dairy Herd', 'herd', 3));
      expect(o.animalIds, ['cow-214']);
      expect(o.productIds, ['fp-dairy-mix'], reason: 'the concentrate of the round is not in her feeding');
    });

    test('the group after a cow fed alone is asked, unless its head count leaves her out', () {
      final luna = event('luna', 'animal', 'cow-214', DateTime.utc(2026, 11, 26, 4, 0), ['fp-dairy-mix'], kind: 'offered');
      final asked = findFeedingOverlap(body('group', 'grp-dairy-herd', ['fp-dairy-mix'], kind: 'delivered', at: DateTime.utc(2026, 11, 26, 4, 5)),
          plan: plan(), events: [luna]);
      expect(asked?.kind, FeedingOverlapKind.groupAfterAnimal);
      expect(asked?.animalIds, ['cow-214']);
      expect(findFeedingOverlap(body('group', 'grp-dairy-herd', ['fp-dairy-mix'], kind: 'delivered', at: DateTime.utc(2026, 11, 26, 4, 5), heads: 2),
          plan: plan(), events: [luna]), isNull, reason: '2 head: the feeding was for the other two');
    });

    test('a supplement, another feed, a refusal, another round, a cow on her own ration, a confirmed one: not asked', () {
      final at = DateTime.utc(2026, 11, 26, 4, 5);
      expect(findFeedingOverlap(body('animal', 'cow-744', ['fp-dairy-concentrate'], at: at), plan: plan(), events: [herd0600]), isNull,
          reason: "Bella's concentrate is her supplement");
      expect(findFeedingOverlap(body('animal', 'cow-214', ['fp-wheat-straw'], at: at), plan: plan(), events: [herd0600]), isNull);
      expect(findFeedingOverlap(body('animal', 'cow-214', ['fp-dairy-mix'], kind: 'refusal', at: at), plan: plan(), events: [herd0600]), isNull);
      expect(findFeedingOverlap(body('animal', 'cow-214', ['fp-dairy-mix'], at: DateTime.utc(2026, 11, 26, 5, 30)), plan: plan(), events: [herd0600]),
          isNull, reason: '90 minutes later is the next round');
      expect(findFeedingOverlap(body('animal', 'cow-clover', ['fp-dairy-mix'], at: at), plan: plan(covered: ['cow-744', 'cow-214'], heads: 2),
          events: [herd0600]), isNull, reason: 'Clover is fed on her own ration, not with the herd');
      expect(findFeedingOverlap(body('animal', 'cow-214', ['fp-dairy-mix'], at: at, confirm: true), plan: plan(), events: [herd0600]), isNull);
      final refusedRound = event('r', 'group', 'grp-dairy-herd', DateTime.utc(2026, 11, 26, 4, 0), ['fp-dairy-mix'], kind: 'refusal');
      final undone = event('u', 'group', 'grp-dairy-herd', DateTime.utc(2026, 11, 26, 4, 0), ['fp-dairy-mix'], status: 'reversed');
      expect(findFeedingOverlap(body('animal', 'cow-214', ['fp-dairy-mix'], at: at), plan: plan(), events: [refusedRound, undone]), isNull,
          reason: 'a refusal or an undone feeding fed nobody');
    });
  });

  group('the question on the feeding form', () {
    /// Luna's feeding form with 20 kg of corn silage typed in. By default
    /// this tablet has seen the herd's silage round five minutes ago; with
    /// [seenRound] false it has not, and the server asks ([serverAsks]).
    Future<SnapshotFarm> openForLuna(WidgetTester tester, {Locale locale = const Locale('en'), bool seenRound = true, String? serverAsks}) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final farm = await SnapshotFarm.open();
      final fiveMinutesAgo = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
      farm.api.snapshot['GET /feeding-events?days=7'] = [
        if (seenRound)
          {'id': 'herd-round', 'subject_type': 'group', 'subject_id': 'grp-dairy-herd', 'event_type': 'delivered', 'status': 'recorded', 'head_count': 3,
           'occurred_at': fiveMinutesAgo.toIso8601String(),
           'components': [{'id': 'c1', 'feed_product_id': 'fp-corn-silage', 'quantity_offered': 60, 'unit': 'kg'}]},
      ];
      final today = farm.api.snapshot['GET /feeding-plan/today'] as Map<String, dynamic>;
      for (final l in today['lines'] as List<dynamic>) {
        final m = l as Map<String, dynamic>;
        if (m['subject_id'] == 'grp-dairy-herd') m['covered_animal_ids'] = ['cow-744', 'cow-214', 'cow-clover'];
      }
      if (serverAsks != null) farm.api.feedingOverlaps['/feeding-events'] = serverAsks;
      await tester.pumpWidget(farm.app(
        Scaffold(body: Builder(builder: (c) => Center(child: TextButton(
          onPressed: () => showFeedingEventDialog(c, subjectType: 'animal', subjectId: 'cow-214', subjectName: 'Luna'),
          child: const Text('open'),
        )))),
        locale: locale,
      ));
      await settle(tester);
      await tester.tap(find.text('open'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(1), '20'); // corn silage
      await settle(tester);
      return farm;
    }

    List<Object?> feedings(SnapshotFarm farm) => [for (final w in farm.api.writes) if (w.$1 == 'POST' && w.$2 == '/feeding-events') w.$3];

    testWidgets("Don't record sends nothing and says why", (tester) async {
      final farm = await openForLuna(tester);
      await tester.tap(find.text('Save'));
      await settle(tester);
      expect(find.text('Fed already this round?'), findsOneWidget);
      expect(find.byKey(const ValueKey('confirmation-detail')), findsOneWidget);
      expect(find.textContaining("is fed with Dairy Herd's ration, and Dairy Herd was given Corn Silage at"), findsOneWidget);
      await tester.tap(find.text("Don't record"));
      await settle(tester);
      expect(feedings(farm), isEmpty);
      expect(find.text('Not recorded: already fed in this round.'), findsOneWidget);
    });

    testWidgets('Record as additional feeding needs the reason, and sends it', (tester) async {
      final farm = await openForLuna(tester);
      await tester.tap(find.text('Save'));
      await settle(tester);
      final record = find.widgetWithText(FilledButton, 'Record as additional feeding');
      expect(tester.widget<FilledButton>(record).onPressed, isNull, reason: 'not without saying why');
      await tester.enterText(find.byKey(const ValueKey('confirmation-reason')), 'Still hungry after the round');
      await settle(tester);
      await tester.tap(record);
      await settle(tester);
      final sent = feedings(farm).single as Map;
      expect(sent['confirm_additional_feeding'], isTrue);
      expect(sent['additional_feeding_reason'], 'Still hungry after the round');
      expect(sent['subject_id'], 'cow-214');
    });

    testWidgets('an overlap only the server could see (another tablet) gets the same question', (tester) async {
      final farm = await openForLuna(tester, seenRound: false,
          serverAsks: "Luna is one of the 3 head Dairy Herd's ration feeds, and Dairy Herd was fed Corn Silage at 06:00 (5 min before). "
              "Record this only if it is extra feed on top of the group's ration — confirm it as an additional feeding and say why.");
      await tester.tap(find.text('Save'));
      await settle(tester);
      expect(find.text('Fed already this round?'), findsOneWidget, reason: 'the feeding question, chosen by the code of the 409');
      expect(find.textContaining('Dairy Herd was fed Corn Silage at 06:00'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('confirmation-reason')), 'Fed apart at the vet stall');
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Record as additional feeding'));
      await settle(tester);
      final writes = [for (final w in farm.api.writes) if (w.$2 == '/feeding-events') w];
      expect(writes.map((w) => w.$1), ['REFUSED POST', 'POST']);
      expect((writes.last.$3 as Map)['confirm_additional_feeding'], isTrue, reason: 'the field the server named');
      expect((writes.last.$3 as Map)['additional_feeding_reason'], 'Fed apart at the vet stall');
    });

    testWidgets('the same question in Arabic', (tester) async {
      await openForLuna(tester, locale: const Locale('ar'));
      await tester.tap(find.text('احفظ'));
      await settle(tester);
      expect(find.text('أُطعمت في هذه الجولة؟'), findsOneWidget);
      expect(find.text('سجّل كإطعام إضافي'), findsOneWidget);
      expect(find.text('لا تسجّل'), findsOneWidget);
      expect(find.textContaining('تُعلف ضمن عليقة Dairy Herd'), findsOneWidget);
    });
  });

  testWidgets('I-7: the quick entry refuses more left over than was given, saying so', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final farm = await SnapshotFarm.open();
    await tester.pumpWidget(farm.app(const AnimalQuickEntryScreen()));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('qr-code-field')), '744');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await settle(tester);
    expect(find.text('Bella'), findsOneWidget);
    final offered = find.byWidgetPredicate((w) => w is TextField && (w.decoration?.labelText ?? '').startsWith('Offered')).first;
    final refused = find.byWidgetPredicate((w) => w is TextField && (w.decoration?.labelText ?? '').startsWith('Refused')).first;
    await tester.enterText(offered, '5');
    await tester.enterText(refused, '9');
    await tester.ensureVisible(find.byKey(const ValueKey('qr-save')));
    await tester.tap(find.byKey(const ValueKey('qr-save')));
    await settle(tester);
    expect(find.textContaining('what was left (9 kg) cannot be more than what was given (5 kg)'), findsOneWidget);
    expect(farm.api.writes.where((w) => w.$2 == '/feeding-events'), isEmpty, reason: 'nothing is sent');
  });

  test('a refusal says which field confirms it, and is kept that way for the sync panel', () {
    final asked = ApiException(409, 'Possible duplicate: Bella is one of the 3 head …',
        code: 'feeding_overlap', confirmField: 'confirm_additional_feeding', reasonField: 'additional_feeding_reason');
    expect(asked.confirmation('Still hungry'), {'confirm_additional_feeding': true, 'additional_feeding_reason': 'Still hungry'});
    expect(asked.isConfirmedBy({'confirm_additional_feeding': true}), isFalse, reason: 'not without the reason');
    expect(asked.isConfirmedBy({'confirm_additional_feeding': true, 'additional_feeding_reason': 'Still hungry'}), isTrue);
    final kept = ApiException.fromRefusal(asked.message, asked.toRefusal());
    expect((kept.code, kept.confirmField, kept.reasonField), (asked.code, asked.confirmField, asked.reasonField));
    expect(ApiException(409, 'Possible duplicate: The same feeding …').confirmation(), {'confirm_duplicate': true});
  });

  testWidgets("I-7: the server's more_than_given is said in the person's language", (tester) async {
    late String english, arabic;
    for (final (locale, set) in [(const Locale('en'), (String v) => english = v), (const Locale('ar'), (String v) => arabic = v)]) {
      await tester.pumpWidget(Localizations(
        locale: locale,
        delegates: const [DefaultWidgetsLocalizations.delegate, DefaultMaterialLocalizations.delegate],
        child: Builder(builder: (c) {
          set(feedingErrorText(c, const WriteResult.fail('Alfalfa Hay: 9 kg consumed is more than the 5 kg offered. …', statusCode: 422, code: 'more_than_given')));
          return const SizedBox();
        }),
      ));
    }
    expect(english, 'What was eaten or left over cannot be more than what was given that day. Check the amounts.');
    expect(arabic, startsWith('لا يمكن أن يكون ما أُكل'));
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
