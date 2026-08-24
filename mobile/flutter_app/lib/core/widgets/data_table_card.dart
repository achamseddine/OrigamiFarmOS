import 'package:flutter/material.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

/// A generic, brand-styled data table used by Feed Inventory, Sales
/// Breakdown, and Expense Breakdown panels. Columns declare relative flex
/// weights; rows are pre-built widgets so callers can mix text, icons, and
/// [StatusPill]s freely per cell.
class FarmDataTable extends StatelessWidget {
  const FarmDataTable({
    super.key,
    required this.columns,
    required this.rows,
    this.columnFlex,
    this.rowHeight = 52,
  });

  final List<String> columns;
  final List<List<Widget>> rows;
  final List<int>? columnFlex;
  final double rowHeight;

  List<int> get _flex => columnFlex ?? List.filled(columns.length, 1);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (var i = 0; i < columns.length; i++)
              Expanded(
                flex: _flex[i],
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    columns[i],
                    style: FarmTypography.textTheme.labelMedium,
                  ),
                ),
              ),
          ],
        ),
        const Divider(height: 1, color: FarmColors.border),
        for (var r = 0; r < rows.length; r++) ...[
          SizedBox(
            height: rowHeight,
            child: Row(
              children: [
                for (var i = 0; i < rows[r].length; i++)
                  Expanded(
                    flex: i < _flex.length ? _flex[i] : 1,
                    child: Align(alignment: Alignment.centerLeft, child: rows[r][i]),
                  ),
              ],
            ),
          ),
          if (r != rows.length - 1) const Divider(height: 1, color: FarmColors.border),
        ],
      ],
    );
  }
}
