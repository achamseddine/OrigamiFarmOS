import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:barcode/barcode.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../domain/entities/animal.dart';
import '../../domain/entities/livestock.dart';
import '../animals/animal_scan.dart';

/// QR labels for animals and pens (ADR-003), made on the tablet.
///
/// The code carries only the opaque `origami://…` payload; the label
/// prints the human-readable tag and name beside it, so a smudged code can
/// still be typed. A pen's label is a *group* label: scanning it opens the
/// pen, never one animal in it.
///
/// Each label is drawn by Flutter and placed in the PDF as an image, so an
/// Arabic name prints exactly as it shows, with the device's own fonts —
/// no font is bundled for this.
class QrLabel {
  const QrLabel({required this.payload, required this.title, required this.subtitle, required this.code});

  final String payload;
  final String title;
  final String subtitle;

  /// What a person types when the code cannot be read: the primary tag.
  final String code;

  factory QrLabel.forAnimal(Animal a, {required String speciesName}) => QrLabel(
        payload: animalQrPayload(a.id),
        title: a.name,
        subtitle: [speciesName, if (a.groupName != null) a.groupName!].join(' · '),
        code: a.primaryId.isEmpty ? a.id.substring(0, a.id.length < 8 ? a.id.length : 8) : a.primaryId,
      );

  factory QrLabel.forGroup(AnimalGroup g, {required String speciesName}) => QrLabel(
        payload: groupQrPayload(g.id),
        title: g.name,
        subtitle: speciesName,
        code: g.id.length > 12 ? g.id.substring(0, 12) : g.id,
      );
}

/// The QR code itself, as crisp vector modules.
class QrCodeView extends StatelessWidget {
  const QrCodeView({super.key, required this.payload, this.size = 160});
  final String payload;
  final double size;

  @override
  Widget build(BuildContext context) {
    final svg = Barcode.qrCode(errorCorrectLevel: BarcodeQRCorrectionLevel.medium).toSvg(payload, width: size, height: size, drawText: false);
    return Semantics(label: payload, child: SvgPicture.string(svg, width: size, height: size));
  }
}

/// One label as it prints: the code, the name, what it is, the tag.
class QrLabelCard extends StatelessWidget {
  const QrLabelCard({super.key, required this.label});
  final QrLabel label;

  static const double width = 210;
  static const double height = 280;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, border: Border.all(color: FarmColors.ink, width: 1.2), borderRadius: BorderRadius.circular(10)),
      child: Column(
        children: [
          QrCodeView(payload: label.payload, size: 150),
          const SizedBox(height: 8),
          Text(label.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.black, fontSize: 18, fontWeight: FontWeight.w800)),
          Text(label.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.black87, fontSize: 12)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(4)),
            child: Text(label.code, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: 1.5)),
          ),
        ],
      ),
    );
  }
}

/// A sheet of label images on A4, three across, cut lines included.
Future<Uint8List> buildQrLabelPdf(List<Uint8List> labelPngs) async {
  final doc = pw.Document(title: 'Origami FarmOS labels');
  const w = 170.0;
  const h = w * QrLabelCard.height / QrLabelCard.width;
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(24),
    build: (_) => [
      pw.Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [for (final png in labelPngs) pw.SizedBox(width: w, height: h, child: pw.Image(pw.MemoryImage(png), fit: pw.BoxFit.contain))],
      ),
    ],
  ));
  return doc.save();
}

/// Preview the labels and print or share them as a PDF.
/// [title] and [note] replace the sheet's heading and explanation — the
/// Add Animal form uses them to say the new animal's code is ready.
Future<void> showQrLabels(BuildContext context, {required List<QrLabel> labels, String? title, String? note}) {
  return showDialog<void>(context: context, builder: (_) => _QrLabelsDialog(labels: labels, title: title, note: note));
}

class _QrLabelsDialog extends StatefulWidget {
  const _QrLabelsDialog({required this.labels, this.title, this.note});
  final List<QrLabel> labels;
  final String? title;
  final String? note;

  @override
  State<_QrLabelsDialog> createState() => _QrLabelsDialogState();
}

class _QrLabelsDialogState extends State<_QrLabelsDialog> {
  late final _keys = [for (final _ in widget.labels) GlobalKey()];
  bool _busy = false;
  String? _error;

  Future<List<Uint8List>> _capture() async {
    final out = <Uint8List>[];
    for (final key in _keys) {
      final boundary = key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) continue;
      final image = await boundary.toImage(pixelRatio: 4);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data != null) out.add(data.buffer.asUint8List());
    }
    return out;
  }

  Future<void> _output({required bool share}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final pdf = await buildQrLabelPdf(await _capture());
      if (share) {
        await Printing.sharePdf(bytes: pdf, filename: 'origami-labels.pdf');
      } else {
        await Printing.layoutPdf(name: 'origami-labels', onLayout: (_) async => pdf);
      }
    } catch (e) {
      if (mounted) setState(() => _error = context.t('qrPrintFailed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title ?? '${context.t('qrLabelsTitle')} · ${widget.labels.length}'),
      content: SizedBox(
        width: 700,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(widget.note ?? context.t('qrLabelsNote'), style: const TextStyle(fontSize: 12.5, color: FarmColors.muted)),
            const SizedBox(height: FarmSpacing.md),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (var i = 0; i < widget.labels.length; i++) RepaintBoundary(key: _keys[i], child: QrLabelCard(label: widget.labels[i])),
            ]),
            if (_error != null) ...[
              const SizedBox(height: FarmSpacing.sm),
              Text(_error!, style: const TextStyle(color: FarmColors.danger, fontSize: 12.5)),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(context.t('close'))),
        OutlinedButton.icon(onPressed: _busy ? null : () => _output(share: true), icon: const Icon(Icons.ios_share, size: 18), label: Text(context.t('qrShare'))),
        FilledButton.icon(
          onPressed: _busy ? null : () => _output(share: false),
          icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.print, size: 18),
          label: Text(context.t('qrPrint')),
        ),
      ],
    );
  }
}
