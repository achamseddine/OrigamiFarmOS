# ADR-003 — On-device QR scanning and printable labels for the worker workflow

**Status:** Accepted (tablet, branch `claude/gifted-davinci-mu9fjj`)

## Context
`docs/QR-ANIMAL-QUICK-ENTRY.md` (PR #11) made the QR scan the worker's way
into an animal's record, but shipped without a camera reader or labels: a
farm needed a USB/Bluetooth keyboard-wedge scanner and an outside tool to
print codes. CLAUDE.md requires an ADR before a foundational dependency,
and its follow-up list names "native camera QR scanning and offline QR
label generation/printing with an ADR" as the next step.

## Decisions

1. **Camera scanning uses `mobile_scanner` (^7.4.2).** It is the maintained
   Flutter plugin for CameraX + ML Kit on Android and AVFoundation on iOS.
   On Android it uses ML Kit's **bundled** barcode model, so decoding works
   in a barn with no network and sends nothing off the device. The scanner
   is restricted to `qrCode` format. The camera permission is declared in
   the manifest and asked for only when the worker opens the scanner; a
   refusal leaves the typed / keyboard-wedge path working.
2. **The scanner sits behind `QrScanSource`.** Screens ask an injectable
   source for a code; the default opens the camera page, tests inject codes.
   Nothing in the domain depends on the plugin.
3. **Labels are made on the tablet with `pdf` (^3.13.1), `printing`
   (^5.15.1) and `barcode` (^2.2.9).** `barcode` is the pure-Dart encoder
   `pdf` already uses; on screen its SVG output is drawn with the existing
   `flutter_svg`. `printing` hands a label sheet to the Android print
   service (any network printer, or save as PDF). No server endpoint is
   needed, and labels can be printed offline.
4. **The payload stays opaque.** `origami://animal/<uuid>` (PR #11) and
   `origami://group/<uuid>` for a herd, pen or flock. No names, health
   facts or credentials in the code; the human-readable tag is printed
   beside it. A scan is navigation only: it never bypasses sign-in, farm
   scope, module permissions or server validation, and anything that is
   not exactly one current animal or group on this farm resolves to
   nothing.
5. **A stall or pen label is a group label, never an animal label.**
   Resolving a pen code opens the group (its feeding round, its members);
   it never picks "whichever animal stood there".

## Consequences
- Four new dependencies (two plugins, two pure Dart). `pubspec.lock` stays
  uncommitted as before; the caret versions above are the reviewed floor.
- The Android build gains CameraX/ML Kit (~3 MB with the bundled model).
- Widget tests never start the camera; device testing in barn light, with
  mud and glare on labels, remains a manual acceptance step.
