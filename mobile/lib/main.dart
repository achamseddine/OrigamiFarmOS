import 'package:flutter/material.dart';
import 'core/theme/theme.dart';

void main() {
  runApp(const FarmOSApp());
}

class FarmOSApp extends StatelessWidget {
  const FarmOSApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Origami FarmOS',
      theme: FarmOSTheme.lightTheme,
      home: const MorningBriefingScreen(),
    );
  }
}

class MorningBriefingScreen extends StatelessWidget {
  const MorningBriefingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Morning Briefing'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Welcome to FarmOS',
                      style: Theme.of(context).textTheme.displaySmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Your tablet-first farm assistant.',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            ElevatedButton(
              onPressed: () {},
              child: const Text('Start My Day'),
            ),
          ],
        ),
      ),
    );
  }
}
