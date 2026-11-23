import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// A report as the person reads it — title, period, headline figures and
/// tables, already in their language — so the screen, the spreadsheet and
/// the PDF say the same thing.
class ReportDoc {
  const ReportDoc({required this.title, required this.period, required this.kpis, required this.tables, this.fileStem = 'report'});

  final String title;
  final String period;
  final List<(String, String)> kpis;
  final List<ReportTable> tables;

  /// The file name without extension: "origami-milk-2026-11-01_2026-11-30".
  final String fileStem;

  /// The spreadsheet: title, period, the figures, then each table under its
  /// title. UTF-8 with a byte-order mark so Excel reads Arabic correctly.
  String toCsv() {
    final b = StringBuffer('﻿');
    void line(List<String> cells) => b.writeln(cells.map(_csvCell).join(','));
    line([title]);
    line([period]);
    b.writeln();
    for (final (label, value) in kpis) {
      line([label, value]);
    }
    for (final t in tables) {
      b.writeln();
      line([t.title]);
      line(t.columns);
      for (final r in t.rows) {
        line(r);
      }
    }
    return b.toString();
  }

  static String _csvCell(String v) => v.contains(RegExp(r'[",\n\r]')) ? '"${v.replaceAll('"', '""')}"' : v;
}

class ReportTable {
  const ReportTable({required this.title, required this.columns, required this.rows, this.numeric = const {}, this.flex});
  final String title;
  final List<String> columns;
  final List<List<String>> rows;

  /// Columns holding numbers: right-aligned on screen.
  final Set<int> numeric;
  final List<int>? flex;
}

/// Saves the spreadsheet: a download in the browser, the share sheet on
/// the tablet (send it by mail or WhatsApp, save it to the device).
Future<void> saveReportCsv(ReportDoc doc) =>
    Printing.sharePdf(bytes: Uint8List.fromList(utf8.encode(doc.toCsv())), filename: '${doc.fileStem}.csv');

/// The report as a PDF of what is on screen: each block ([blocks], painted
/// widgets) becomes an image — Arabic prints exactly as it shows, with the
/// device's fonts — cut into pages when it is taller than one.
Future<Uint8List> reportPdf(List<GlobalKey> blocks, {String title = 'Origami FarmOS report'}) async {
  const format = PdfPageFormat.a4;
  const margin = 28.0;
  final pageWidth = format.width - 2 * margin;
  final pageHeight = format.height - 2 * margin;
  final parts = <(Uint8List, double, double)>[];
  for (final key in blocks) {
    final boundary = key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null || !boundary.hasSize) continue;
    final image = await boundary.toImage(pixelRatio: 2);
    final scale = pageWidth / image.width;
    final sliceHeight = (pageHeight / scale).floor();
    for (var y = 0; y < image.height; y += sliceHeight) {
      final h = (image.height - y) < sliceHeight ? image.height - y : sliceHeight;
      final png = await _slice(image, y, h);
      parts.add((png, pageWidth, h * scale));
    }
  }
  final doc = pw.Document(title: title);
  doc.addPage(pw.MultiPage(
    pageFormat: format,
    margin: const pw.EdgeInsets.all(margin),
    build: (_) => [
      for (final (png, w, h) in parts) ...[
        pw.SizedBox(width: w, height: h, child: pw.Image(pw.MemoryImage(png), fit: pw.BoxFit.fill)),
        pw.SizedBox(height: 6),
      ],
    ],
  ));
  return doc.save();
}

Future<Uint8List> _slice(ui.Image image, int top, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, top.toDouble(), image.width.toDouble(), height.toDouble()),
    Rect.fromLTWH(0, 0, image.width.toDouble(), height.toDouble()),
    Paint(),
  );
  final sliced = await recorder.endRecording().toImage(image.width, height);
  final data = await sliced.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<void> printReport(List<GlobalKey> blocks, ReportDoc doc) async {
  final pdf = await reportPdf(blocks, title: doc.title);
  await Printing.layoutPdf(name: doc.fileStem, onLayout: (_) async => pdf);
}

Future<void> shareReportPdf(List<GlobalKey> blocks, ReportDoc doc) async {
  final pdf = await reportPdf(blocks, title: doc.title);
  await Printing.sharePdf(bytes: pdf, filename: '${doc.fileStem}.pdf');
}
