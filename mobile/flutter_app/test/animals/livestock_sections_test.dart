import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:farmos/api/api_client.dart';
import 'package:farmos/domain/entities/animal.dart';
import 'package:farmos/features/animals/animal_herd_section.dart';
import 'package:farmos/features/animals/animal_reproduction_section.dart';
import 'package:farmos/providers/access_provider.dart';
import 'package:farmos/providers/herd_records_provider.dart';
import 'package:farmos/providers/livestock_provider.dart';

/// A manager holds every module; the section's buttons follow the access
/// the server granted, so the test grants it the same way.
class _Access extends AccessProvider {
  _Access({required this.full}) : super(apiClient: ApiClient(baseUrl: 'http://test.invalid'));
  final bool full;
  @override
  bool isModuleAvailable(String code) => full;
  @override
  bool canCreate(String moduleCode) => full;
  @override
  bool canEdit(String moduleCode) => full;
}

void main() {
  late Map<String, dynamic> snapshot;
  setUpAll(() {
    snapshot = jsonDecode(File('assets/demo/snapshot.json').readAsStringSync()) as Map<String, dynamic>;
  });

  Widget host(Widget child, {bool full = true}) {
    final api = ApiClient(baseUrl: 'http://test.invalid');
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AccessProvider>(create: (_) => _Access(full: full)),
        ChangeNotifierProvider(create: (_) => HerdRecordsProvider(apiClient: api)),
        ChangeNotifierProvider(create: (_) => LivestockProvider(apiClient: api)),
      ],
      child: MaterialApp(locale: const Locale('en'), home: Scaffold(body: SingleChildScrollView(child: SizedBox(width: 760, child: child)))),
    );
  }

  Map<String, dynamic> twin(String id) => snapshot['GET /animals/$id'] as Map<String, dynamic>;

  testWidgets("Bella's card: pregnant and due, with the actions a pregnant dairy cow has", (tester) async {
    final t = twin('cow-744');
    await tester.pumpWidget(host(AnimalReproductionSection(animal: Animal.fromJson(t), twin: t, loading: false)));
    expect(find.text('Reproduction & milking'), findsOneWidget);
    expect(find.textContaining('Pregnant · day'), findsOneWidget);
    expect(find.textContaining('due'), findsWidgets);
    expect(find.text('Pregnancy check'), findsOneWidget);
    expect(find.text('Calving'), findsOneWidget, reason: 'the species word, from the catalog');
    expect(find.text('Pregnancy loss'), findsOneWidget);
    expect(find.text('Dry off'), findsOneWidget);
    expect(find.text('Breeding'), findsNothing, reason: 'a pregnant cow is not bred again');
  });

  testWidgets('Daisy waits for her check; a viewer sees the card but no buttons', (tester) async {
    final t = twin('sheep-s045');
    await tester.pumpWidget(host(AnimalReproductionSection(animal: Animal.fromJson(t), twin: t, loading: false), full: false));
    expect(find.text('Served — waiting for a pregnancy check'), findsOneWidget);
    expect(find.text('Pregnancy check'), findsNothing);
  });

  testWidgets('a hen shows no reproduction card at all', (tester) async {
    final t = twin('hen-247');
    await tester.pumpWidget(host(AnimalReproductionSection(animal: Animal.fromJson(t), twin: t, loading: false)));
    expect(find.text('Reproduction & milking'), findsNothing);
  });

  testWidgets("Luna's herd card shows her herd and history", (tester) async {
    final t = twin('cow-214');
    await tester.pumpWidget(host(AnimalHerdSection(animal: Animal.fromJson(t), twin: t, loading: false)));
    expect(find.text('Herd & family'), findsOneWidget);
    expect(find.textContaining('Dairy Herd'), findsWidgets);
    expect(find.text('Move to group'), findsOneWidget);
    expect(find.textContaining('Location:'), findsOneWidget);
  });

  testWidgets('an animal that left says so, and offers no moves', (tester) async {
    final t = {...twin('cow-214'), 'active': false, 'lifecycle_status': 'sold', 'exited_at': '2026-11-01T08:00:00Z', 'groups': <dynamic>[]};
    await tester.pumpWidget(host(AnimalHerdSection(animal: Animal.fromJson(t), twin: t, loading: false)));
    expect(find.textContaining('Left the farm · Sold'), findsOneWidget);
    expect(find.text('Move to group'), findsNothing);
  });
}
