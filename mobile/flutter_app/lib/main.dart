import 'package:flutter/material.dart';
import 'app/app.dart';
import 'data/local/local_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Opened before the first frame so the very first request already knows
  // whether it can fall back to the cache. Never throws — a device
  // without working SQLite gets an online-only app rather than no app.
  final store = await LocalStore.open();
  runApp(FarmOSApp(store: store));
}
