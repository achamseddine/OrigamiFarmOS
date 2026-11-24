import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Opens [url] in a new browser tab.
Future<bool> openExternalUrl(String url) async {
  globalContext.callMethod('open'.toJS, url.toJS, '_blank'.toJS);
  return true;
}

/// Loads the page again from the farm server: the newest web app deployed
/// there replaces the one this tab has kept.
void reloadApp() {
  final location = globalContext['location'] as JSObject?;
  location?.callMethod('reload'.toJS);
}
