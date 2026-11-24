import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../build_info.dart';
import 'open_url.dart';

/// Where new tablet builds are published: the public GitHub releases of
/// this repository, from the farm's main tablet branch only (builds from a
/// developer's branch are published there too, and are not for the farm).
/// Both can be changed at build time.
const String kUpdateRepository = String.fromEnvironment('UPDATE_REPOSITORY', defaultValue: 'achamseddine/OrigamiFarmOS');
const String kUpdateBranch = String.fromEnvironment('UPDATE_BRANCH', defaultValue: 'claude/origami-farmos-tablet-mvp-u88i3e');

/// A newer build than this one.
@immutable
class AppRelease {
  const AppRelease({required this.buildNumber, required this.label, this.downloadUrl, this.pageUrl, this.publishedAt});

  /// The CI run number — what "newer" is decided on.
  final int buildNumber;

  /// "0.7.85" as the sign-in screen shows it.
  final String label;

  /// The APK itself (tablet); null on the web.
  final String? downloadUrl;
  final String? pageUrl;
  final DateTime? publishedAt;
}

/// Is there a newer version of the app, and get it: on the tablet the
/// newest APK built from the main branch (Settings → Update downloads it
/// and Android installs it over this one, keeping the farm's data); in a
/// browser the newest web app deployed on the farm server (reload).
///
/// Checked a few seconds after sign-in and then every few hours; a newer
/// build shows a notice under the top bar and in the notifications until
/// it is installed or put off.
class AppUpdateProvider extends ChangeNotifier {
  AppUpdateProvider({http.Client? client, String? currentBuild, bool? web, Uri? webBase})
      : _client = client ?? http.Client(),
        currentBuild = currentBuild ?? kAppBuild,
        _web = web ?? kIsWeb,
        _webBase = webBase;

  final http.Client _client;
  final bool _web;
  final Uri? _webBase;

  /// This build ("0.7.84", "web 0.7.13", or "dev" from a laptop).
  final String currentBuild;

  AppRelease? latest;
  bool checking = false;
  String? error;
  DateTime? checkedAt;
  int? _dismissed;
  Timer? _first;
  Timer? _timer;

  bool get isWeb => _web;

  /// The number at the end of a build label: "0.7.84" → 84; "dev" → null.
  static int? buildNumberOf(String build) {
    final m = RegExp(r'(\d+)\s*$').firstMatch(build);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  int? get currentBuildNumber => buildNumberOf(currentBuild);

  /// A developer's own build cannot tell whether a release is newer.
  bool get isDevBuild => currentBuildNumber == null;

  bool get updateAvailable {
    final now = currentBuildNumber;
    return latest != null && now != null && latest!.buildNumber > now;
  }

  /// The notice is shown until the update is installed or put off.
  bool get showNotice => updateAvailable && _dismissed != latest!.buildNumber;

  /// Checks now, then every [every] while the app runs.
  void start({Duration firstAfter = const Duration(seconds: 8), Duration every = const Duration(hours: 4)}) {
    _first?.cancel();
    _timer?.cancel();
    _first = Timer(firstAfter, check);
    _timer = Timer.periodic(every, (_) => check());
  }

  void dismiss() {
    if (latest == null) return;
    _dismissed = latest!.buildNumber;
    notifyListeners();
  }

  Future<void> check() async {
    if (checking) return;
    checking = true;
    error = null;
    notifyListeners();
    try {
      latest = _web ? await _latestWeb() : await _latestTablet();
      checkedAt = DateTime.now();
    } catch (e) {
      error = '$e';
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  /// The newest tablet release built from [kUpdateBranch] that carries an APK.
  Future<AppRelease?> _latestTablet() async {
    final res = await _client
        .get(Uri.parse('https://api.github.com/repos/$kUpdateRepository/releases?per_page=40'), headers: {'Accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw Exception('GitHub answered ${res.statusCode}');
    AppRelease? best;
    for (final r in jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>) {
      final release = (r as Map).cast<String, dynamic>();
      final tag = '${release['tag_name'] ?? ''}';
      if (!tag.startsWith('tablet-v') || release['draft'] == true) continue;
      if (!'${release['body'] ?? ''}'.contains('on branch `$kUpdateBranch`')) continue;
      final n = RegExp(r'build-(\d+)$').firstMatch(tag);
      if (n == null) continue;
      final apk = [
        for (final a in (release['assets'] as List<dynamic>? ?? const []))
          if ('${(a as Map)['name']}'.toLowerCase().endsWith('.apk')) a,
      ];
      if (apk.isEmpty) continue;
      final build = int.parse(n.group(1)!);
      if (best != null && best.buildNumber >= build) continue;
      final version = RegExp(r'^tablet-v(\d+)\.(\d+)').firstMatch(tag);
      best = AppRelease(
        buildNumber: build,
        label: version == null ? 'build $build' : '${version.group(1)}.${version.group(2)}.$build',
        downloadUrl: '${apk.first['browser_download_url']}',
        pageUrl: release['html_url'] as String?,
        publishedAt: DateTime.tryParse('${release['published_at'] ?? ''}'),
      );
    }
    return best;
  }

  /// The web app the farm server has now (`version.json` next to the page).
  Future<AppRelease?> _latestWeb() async {
    final base = _webBase ?? Uri.base;
    final url = base.resolve('version.json').replace(queryParameters: {'t': '${DateTime.now().millisecondsSinceEpoch}'});
    final res = await _client.get(url).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return null;
    final json = (jsonDecode(utf8.decode(res.bodyBytes)) as Map).cast<String, dynamic>();
    final build = int.tryParse('${json['build_number'] ?? ''}');
    if (build == null) return null;
    return AppRelease(buildNumber: build, label: '${json['version'] ?? build}');
  }

  /// Gets the newer version: the tablet downloads the APK (the browser
  /// fetches it and Android asks to install it over this one); the web
  /// app reloads from the farm server.
  Future<bool> install() async {
    final r = latest;
    if (_web) {
      reloadApp();
      return true;
    }
    final url = r?.downloadUrl ?? r?.pageUrl;
    if (url == null) return false;
    return openExternalUrl(url);
  }

  @override
  void dispose() {
    _first?.cancel();
    _timer?.cancel();
    super.dispose();
  }
}
