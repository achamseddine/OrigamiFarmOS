import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/colors.dart';
import '../core/theme/spacing.dart';
import '../core/theme/typography.dart';
import '../core/widgets/section_card.dart';
import '../domain/entities/animal.dart';
import '../domain/entities/inventory.dart';
import '../providers/animals_provider.dart';
import '../providers/feed_provider.dart';
import '../providers/tasks_provider.dart';

enum LiveDataSection { overview, animals, inventory, milk, eggs, health, produce, finance, settings }

/// Database-backed replacement for the former mock-data dashboards.
/// Sections without a synchronized local table show an explicit empty state
/// instead of inventing values, trends, alerts, or farm identities.
class LiveDataScreen extends StatelessWidget {
  const LiveDataScreen({super.key, required this.section});

  final LiveDataSection section;

  @override
  Widget build(BuildContext context) {
    final animals = context.watch<AnimalsProvider>().animals;
    final inventory = context.watch<FeedProvider>().items;
    final tasks = context.watch<TasksProvider>().tasks;
    final (title, subtitle) = _copy(section);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: FarmTypography.display(size: 28)),
          const SizedBox(height: 2),
          Text(subtitle, style: FarmTypography.textTheme.bodyMedium),
          const SizedBox(height: FarmSpacing.md),
          if (section == LiveDataSection.overview)
            _Overview(animals: animals, inventory: inventory, openTasks: tasks.where((task) => task.status.name != 'done').length)
          else if (section == LiveDataSection.animals)
            _Animals(animals: animals)
          else if (section == LiveDataSection.inventory)
            _Inventory(items: inventory)
          else
            const _EmptyDatabaseState(),
        ],
      ),
    );
  }
}

(String, String) _copy(LiveDataSection section) => switch (section) {
      LiveDataSection.overview => ("Today's Priorities", 'Current records synchronized to this device.'),
      LiveDataSection.animals => ('Animals', 'Animal records stored in the local database.'),
      LiveDataSection.inventory => ('Feed Inventory', 'Inventory records stored in the local database.'),
      LiveDataSection.milk => ('Milk Production', 'Milk records synchronized to this device.'),
      LiveDataSection.eggs => ('Egg Production', 'Egg records synchronized to this device.'),
      LiveDataSection.health => ('Health Intelligence', 'Evidence-backed health records and recommendations.'),
      LiveDataSection.produce => ('Produce & Harvest', 'Field and harvest records synchronized to this device.'),
      LiveDataSection.finance => ('Sales & Finance', 'Sales and expense records synchronized to this device.'),
      LiveDataSection.settings => ('Settings', 'Farm and account settings are supplied after authentication.'),
    };

class _Overview extends StatelessWidget {
  const _Overview({required this.animals, required this.inventory, required this.openTasks});
  final List<Animal> animals;
  final List<InventoryItem> inventory;
  final int openTasks;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Database summary',
      child: Wrap(
        spacing: FarmSpacing.xl,
        runSpacing: FarmSpacing.md,
        children: [
          _Count(label: 'Animals', value: animals.length),
          _Count(label: 'Inventory items', value: inventory.length),
          _Count(label: 'Open tasks', value: openTasks),
        ],
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.label, required this.value});
  final String label;
  final int value;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 150,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$value', style: FarmTypography.display(size: 30)),
          Text(label, style: FarmTypography.textTheme.bodySmall),
        ]),
      );
}

class _Animals extends StatelessWidget {
  const _Animals({required this.animals});
  final List<Animal> animals;
  @override
  Widget build(BuildContext context) => SectionCard(
        title: 'Animal records (${animals.length})',
        child: animals.isEmpty
            ? const _EmptyDatabaseState()
            : Column(
                children: [
                  for (final animal in animals)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(animal.name),
                      subtitle: Text('${animal.species.label} • ${animal.tag} • ${animal.location}'),
                      trailing: Text(animal.status.name),
                    ),
                ],
              ),
      );
}

class _Inventory extends StatelessWidget {
  const _Inventory({required this.items});
  final List<InventoryItem> items;
  @override
  Widget build(BuildContext context) => SectionCard(
        title: 'Inventory records (${items.length})',
        child: items.isEmpty
            ? const _EmptyDatabaseState()
            : Column(
                children: [
                  for (final item in items)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(item.name),
                      subtitle: Text(item.category),
                      trailing: Text('${item.currentQty.toStringAsFixed(1)} ${item.unit}'),
                    ),
                ],
              ),
      );
}

class _EmptyDatabaseState extends StatelessWidget {
  const _EmptyDatabaseState();
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(FarmSpacing.xl),
        decoration: BoxDecoration(color: FarmColors.card, borderRadius: FarmRadii.card, border: Border.all(color: FarmColors.border)),
        child: Column(children: [
          const Icon(Icons.storage_outlined, color: FarmColors.muted, size: 32),
          const SizedBox(height: FarmSpacing.sm),
          Text('No synchronized records yet', style: FarmTypography.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('Sign in and synchronize the device to load database records.', style: FarmTypography.textTheme.bodySmall, textAlign: TextAlign.center),
        ]),
      );
}
