import 'package:flutter/material.dart';

/// Arrows that point the way the language runs.
///
/// Flutter's `Icons.chevron_right` is a *physical* right — it keeps
/// pointing right in Arabic, where forward is left. On a tablet handed to
/// someone who is not going to puzzle it out, an arrow aimed the wrong way
/// is not a rough edge: it is the app telling them to go the wrong
/// direction. These pick their glyph from [Directionality], so "next" and
/// "back" mean the same thing in both languages.

/// Points at what opens next: right in English, left in Arabic.
class ForwardChevron extends StatelessWidget {
  const ForwardChevron({super.key, this.size = 18, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Icon(rtl ? Icons.chevron_left : Icons.chevron_right, size: size, color: color);
  }
}

/// Points back the way you came.
class BackChevron extends StatelessWidget {
  const BackChevron({super.key, this.size, this.color});

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Icon(rtl ? Icons.chevron_right : Icons.chevron_left, size: size, color: color);
  }
}

/// The long arrow between steps of a sequence.
class ForwardArrow extends StatelessWidget {
  const ForwardArrow({super.key, this.size, this.color});

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Icon(rtl ? Icons.arrow_back : Icons.arrow_forward, size: size, color: color);
  }
}
