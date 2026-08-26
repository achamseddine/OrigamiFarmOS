import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/bekaa_backdrop.dart';

/// Neutral entry screen. Farm and user identity are loaded only after
/// authentication/synchronization; no sample identity is embedded here.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key, required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FarmColors.stone,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Padding(
              padding: const EdgeInsets.all(FarmSpacing.xl),
              child: ClipRRect(
                borderRadius: FarmRadii.panel,
                child: Stack(
                  children: [
                    const Positioned.fill(child: BekaaBackdrop()),
                    Positioned.fill(child: ColoredBox(color: FarmColors.stone.withOpacity(0.90))),
                    Padding(
                      padding: const EdgeInsets.all(FarmSpacing.xl),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SvgPicture.asset('assets/logo/origami-farmos-mark.svg', width: 64, height: 64),
                          const SizedBox(height: FarmSpacing.md),
                          Text('Origami FarmOS', style: FarmTypography.display(size: 34)),
                          const SizedBox(height: FarmSpacing.sm),
                          Text(
                            'Open your local farm workspace. Records appear after the device has synchronized with your account.',
                            style: FarmTypography.textTheme.bodyLarge,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: FarmSpacing.xl),
                          SizedBox(
                            width: 300,
                            child: ElevatedButton.icon(
                              onPressed: onStart,
                              icon: const Icon(Icons.login),
                              label: Text(context.t('startMyDay')),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
