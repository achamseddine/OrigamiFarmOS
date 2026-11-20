import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../i18n/strings.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';

/// A form or a record opened over a page — a mix, a delivery, a feeding,
/// a mix's history.
///
/// On a tablet or a phone it takes the whole screen: the title and a close
/// button at the top, the form at a readable width scrolling as one page,
/// and Cancel / Save in a bar at the bottom that stays above the keyboard.
/// A dialog there left a small window between the title and the keyboard,
/// and a mix's ingredient rows scrolled inside it unreadably. On a large
/// screen — a desktop browser — it stays a dialog. Same widget and rules on
/// the tablet and the web: only the screen size decides.
///
/// [content] is the form itself, not scrollable: this scrolls it.
class FarmFormDialog extends StatelessWidget {
  const FarmFormDialog({super.key, required this.title, required this.content, this.actions = const [], this.width = 560});

  final Widget title;
  final Widget content;
  final List<Widget> actions;

  /// The dialog's width on a large screen. Full screen, the form is at
  /// least [fullScreenWidth] wide when there is room.
  final double width;

  /// Below this shortest side (logical pixels) forms take the whole
  /// screen: every tablet in either orientation, phones, small laptops.
  static const double fullScreenBelow = 900;

  /// The readable width of a form shown full screen.
  static const double fullScreenWidth = 760;

  static bool isFullScreen(BuildContext context) => MediaQuery.sizeOf(context).shortestSide < fullScreenBelow;

  @override
  Widget build(BuildContext context) {
    if (!isFullScreen(context)) {
      return AlertDialog(
        title: title,
        content: SizedBox(width: width, child: SingleChildScrollView(child: content)),
        actions: actions,
      );
    }
    final formWidth = math.max(width, fullScreenWidth);
    return Dialog.fullscreen(
      key: const ValueKey('form-full-screen'),
      backgroundColor: FarmColors.stone,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(FarmSpacing.xs, FarmSpacing.sm, FarmSpacing.lg, FarmSpacing.sm),
            child: Row(children: [
              IconButton(
                tooltip: context.t('close'),
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.maybePop(context),
              ),
              const SizedBox(width: FarmSpacing.xs),
              Expanded(
                child: DefaultTextStyle.merge(
                  style: FarmTypography.textTheme.titleLarge,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  child: title,
                ),
              ),
            ]),
          ),
          const Divider(height: 1, color: FarmColors.border),
          Expanded(
            child: LayoutBuilder(builder: (context, c) {
              final side = c.maxWidth > formWidth + 2 * FarmSpacing.lg ? (c.maxWidth - formWidth) / 2 : FarmSpacing.lg;
              return SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(side, FarmSpacing.lg, side, FarmSpacing.xl),
                child: content,
              );
            }),
          ),
          if (actions.isNotEmpty) ...[
            const Divider(height: 1, color: FarmColors.border),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.lg, vertical: FarmSpacing.sm + 4),
              child: OverflowBar(
                alignment: MainAxisAlignment.end,
                overflowAlignment: OverflowBarAlignment.end,
                spacing: FarmSpacing.sm,
                overflowSpacing: FarmSpacing.sm,
                children: actions,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
