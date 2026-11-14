import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';

/// Where a code comes from. The default opens the tablet's camera; a test
/// (or a farm that uses a keyboard-wedge reader only) puts its own here.
/// Nothing in the domain knows which one is in use (ADR-003).
abstract class QrScanSource {
  const QrScanSource();
  Future<String?> scan(BuildContext context);
}

class CameraQrScanSource extends QrScanSource {
  const CameraQrScanSource();

  @override
  Future<String?> scan(BuildContext context) =>
      Navigator.of(context).push<String>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const QrScannerPage()));
}

class QrScan {
  QrScan._();

  /// Replaced in tests; the camera everywhere else.
  static QrScanSource source = const CameraQrScanSource();
}

/// The camera, full screen, reading QR codes only — on the device, with
/// ML Kit's bundled model, so it works with no signal in the barn. The
/// first code read comes back to the screen that asked; a buzz says it was
/// read. A torch for the dark end of the shed; a refused camera permission
/// says so and leaves the typed / reader path to the screen behind.
class QrScannerPage extends StatefulWidget {
  const QrScannerPage({super.key});

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.noDuplicates);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final code in capture.barcodes) {
      final value = code.rawValue;
      if (value == null || value.trim().isEmpty) continue;
      _done = true;
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop(value);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FarmColors.black,
      appBar: AppBar(
        backgroundColor: FarmColors.black,
        foregroundColor: FarmColors.white,
        title: Text(context.t('qrScanTitle')),
        actions: [
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controller,
            builder: (context, state, _) {
              if (state.torchState == TorchState.unavailable) return const SizedBox.shrink();
              final on = state.torchState == TorchState.on;
              return IconButton(
                tooltip: context.t('qrTorch'),
                onPressed: _controller.toggleTorch,
                icon: Icon(on ? Icons.flash_on : Icons.flash_off),
              );
            },
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _CameraError(error: error),
          ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  border: Border.all(color: FarmColors.white, width: 3),
                  borderRadius: BorderRadius.circular(FarmRadii.md),
                ),
              ),
            ),
          ),
          Positioned(
            left: FarmSpacing.lg,
            right: FarmSpacing.lg,
            bottom: FarmSpacing.xl,
            child: Text(
              context.t('qrScanHint'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: FarmColors.white, fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraError extends StatelessWidget {
  const _CameraError({required this.error});
  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    return ColoredBox(
      color: FarmColors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(FarmSpacing.lg),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.no_photography_outlined, color: FarmColors.white, size: 40),
            const SizedBox(height: FarmSpacing.md),
            Text(
              context.t(denied ? 'qrCameraDenied' : 'qrCameraError'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: FarmColors.white, fontSize: 15),
            ),
            const SizedBox(height: FarmSpacing.md),
            OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: FarmColors.white, side: const BorderSide(color: FarmColors.white)),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.t('qrTypeInstead')),
            ),
          ]),
        ),
      ),
    );
  }
}
