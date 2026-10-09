// Web: stop HTML <video> from stealing taps on Mobile Chrome.
import 'package:web/web.dart' as web;

bool _cssInjected = false;

void disableHtmlVideoPointerEvents() {
  if (!_cssInjected) {
    _cssInjected = true;
    const id = 'wamu-disable-video-pointer';
    if (web.document.querySelector('#$id') == null) {
      final style = web.HTMLStyleElement()
        ..id = id
        ..textContent = 'video { pointer-events: none !important; }';
      web.document.head?.append(style);
    }
  }

  final videos = web.document.querySelectorAll('video');
  for (var i = 0; i < videos.length; i++) {
    final node = videos.item(i);
    if (node == null) continue;
    try {
      final el = node as web.HTMLVideoElement;
      el.style.pointerEvents = 'none';
    } catch (_) {
      // ignore non-video nodes
    }
  }
}
