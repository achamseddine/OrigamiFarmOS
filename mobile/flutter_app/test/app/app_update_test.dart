import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:farmos/app/update/app_update_provider.dart';
import 'package:farmos/app/update/update_ui.dart';

import '../support/snapshot_farm.dart';

/// Settings → App updates (v0.8.0): the newest tablet build from the main
/// branch, an Update button, and a notice when one is out. On the web: the
/// newest web app on the farm server, and Reload.
void main() {
  Map<String, Object?> release(int build, {String branch = 'claude/origami-farmos-tablet-mvp-u88i3e', bool apk = true, bool draft = false}) => {
        'tag_name': 'tablet-v0.8.0-build-$build',
        'draft': draft,
        'body': '**Build 0.7.$build** — commit abc on branch `$branch`.',
        'html_url': 'https://github.com/achamseddine/OrigamiFarmOS/releases/tag/tablet-v0.8.0-build-$build',
        'published_at': '2026-11-24T08:00:00Z',
        'assets': [
          if (apk) {'name': 'app-release.apk', 'browser_download_url': 'https://github.com/x/releases/download/tablet-v0.8.0-build-$build/app-release.apk'},
        ],
      };

  AppUpdateProvider tablet(List<Map<String, Object?>> releases, {String current = '0.7.84'}) => AppUpdateProvider(
        currentBuild: current,
        web: false,
        client: MockClient((req) async {
          expect(req.url.host, 'api.github.com');
          return http.Response.bytes(utf8.encode(jsonEncode(releases)), 200, headers: {'content-type': 'application/json; charset=utf-8'});
        }),
      );

  group('the newest tablet build', () {
    test('from the main branch only, with an APK, not a draft', () async {
      final u = tablet([
        release(83),
        release(90, branch: 'claude/gifted-davinci-mu9fjj'),
        release(91, apk: false),
        release(92, draft: true),
        release(85),
      ]);
      await u.check();
      expect(u.latest!.buildNumber, 85);
      expect(u.latest!.label, '0.8.85');
      expect(u.latest!.downloadUrl, endsWith('tablet-v0.8.0-build-85/app-release.apk'));
      expect(u.updateAvailable, isTrue);
      expect(u.showNotice, isTrue);
      u.dismiss();
      expect(u.showNotice, isFalse, reason: 'put off until the next build');
      expect(u.updateAvailable, isTrue, reason: 'still offered in Settings');
    });

    test('nothing newer, nothing to do', () async {
      final u = tablet([release(84), release(80)]);
      await u.check();
      expect(u.updateAvailable, isFalse);
      expect(u.error, isNull);
    });

    test('a developer build cannot tell', () async {
      final u = tablet([release(85)], current: 'dev');
      await u.check();
      expect(u.isDevBuild, isTrue);
      expect(u.updateAvailable, isFalse);
    });

    test('no internet is said, not thrown', () async {
      final u = AppUpdateProvider(currentBuild: '0.7.84', web: false, client: MockClient((_) async => http.Response('rate limited', 403)));
      await u.check();
      expect(u.error, isNotNull);
      expect(u.updateAvailable, isFalse);
    });

    test('build numbers are read from the end of the label', () {
      expect(AppUpdateProvider.buildNumberOf('0.7.84'), 84);
      expect(AppUpdateProvider.buildNumberOf('web 0.7.13'), 13);
      expect(AppUpdateProvider.buildNumberOf('dev'), isNull);
    });
  });

  test('the web app compares with what the farm server has', () async {
    final u = AppUpdateProvider(
      currentBuild: 'web 0.7.13',
      web: true,
      webBase: Uri.parse('https://farm.example/app/'),
      client: MockClient((req) async {
        expect(req.url.path, '/app/version.json');
        return http.Response(jsonEncode({'app_name': 'farmos', 'version': '0.7.14', 'build_number': '14'}), 200);
      }),
    );
    await u.check();
    expect(u.latest!.label, '0.7.14');
    expect(u.updateAvailable, isTrue);
  });

  group('on screen', () {
    Future<SnapshotFarm> open(WidgetTester tester, Widget home) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final farm = await SnapshotFarm.open();
      farm.updates.latest = const AppRelease(buildNumber: 85, label: '0.8.85', downloadUrl: 'https://example.invalid/app.apk');
      await tester.pumpWidget(farm.app(Scaffold(body: home)));
      await tester.pump(const Duration(milliseconds: 300));
      return farm;
    }

    testWidgets('Settings shows the newer version and the Update button', (tester) async {
      await open(tester, const SingleChildScrollView(child: AppUpdateCard()));
      expect(find.byKey(const ValueKey('app-update-card')), findsOneWidget);
      expect(find.text('Update to 0.8.85'), findsOneWidget);
      expect(find.byKey(const ValueKey('app-update-check')), findsOneWidget);
    });

    testWidgets('the notice under the top bar, put off with Later', (tester) async {
      await open(tester, const Column(children: [AppUpdateBanner(), AppUpdateNotice()]));
      expect(find.byKey(const ValueKey('app-update-banner')), findsOneWidget);
      expect(find.byKey(const ValueKey('app-update-notice')), findsOneWidget);
      await tester.tap(find.text('Later'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('app-update-banner')), findsNothing);
      expect(find.byKey(const ValueKey('app-update-notice')), findsOneWidget, reason: 'the notifications still say so');
    });
  });
}
