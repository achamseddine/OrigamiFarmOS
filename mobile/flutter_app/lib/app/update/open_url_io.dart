import 'package:flutter/services.dart';

const _channel = MethodChannel('farmos/system');

/// Opens [url] in the device's browser (Android: MainActivity's
/// `farmos/system` → an ACTION_VIEW intent). For an APK the browser
/// downloads it and Android offers to install it over this one.
Future<bool> openExternalUrl(String url) async {
  try {
    return await _channel.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// Only the web app reloads itself; the tablet installs a new APK.
void reloadApp() {}
