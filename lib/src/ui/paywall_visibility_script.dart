/// Installed before paywall scripts so their animation frames can be suspended.
const paywallVisibilityScript = r'''
<script>
(function () {
  if (window.__mySuperWallSetVisible) return;
  var visible = true;
  var request = window.requestAnimationFrame.bind(window);
  var cancel = window.cancelAnimationFrame.bind(window);
  window.__mySuperWallRequestPaint = request;
  var frames = new Map();
  var nextId = 0;
  var pausedAnimations = new Set();
  var pausedMedia = new Set();
  var style = document.createElement('style');
  style.textContent = 'html[data-msw-paused],html[data-msw-paused] *,html[data-msw-paused] *::before,html[data-msw-paused] *::after{animation-play-state:paused!important}';
  function installStyle() {
    var parent = document.head || document.documentElement;
    if (parent && !style.parentNode) parent.appendChild(style);
  }
  installStyle();
  document.addEventListener('DOMContentLoaded', installStyle, { once: true });

  function schedule(id, frame) {
    frame.nativeId = request(function (time) {
      frame.nativeId = null;
      if (!visible) return;
      frames.delete(id);
      frame.callback.call(window, time);
    });
  }
  window.requestAnimationFrame = function (callback) {
    var id = ++nextId;
    var frame = { callback: callback, nativeId: null };
    frames.set(id, frame);
    if (visible) schedule(id, frame);
    return id;
  };
  window.cancelAnimationFrame = function (id) {
    var frame = frames.get(id);
    if (!frame) return;
    if (frame.nativeId !== null) cancel(frame.nativeId);
    frames.delete(id);
  };

  function pauseContent() {
    if (document.getAnimations) {
      document.getAnimations().forEach(function (animation) {
        if (animation.playState === 'running') {
          pausedAnimations.add(animation);
          animation.pause();
        }
      });
    }
    if (document.documentElement) document.documentElement.setAttribute('data-msw-paused', '');
    document.querySelectorAll('video,audio').forEach(function (media) {
      if (!media.paused) {
        pausedMedia.add(media);
        media.pause();
      }
    });
  }
  document.addEventListener('play', function (event) {
    if (!visible && event.target && event.target.pause) {
      pausedMedia.add(event.target);
      event.target.pause();
    }
  }, true);
  var observer = new MutationObserver(function () {
    if (!visible) pauseContent();
  });
  function observeContent() {
    if (document.documentElement) observer.observe(document.documentElement, { childList: true, subtree: true });
    if (!visible) pauseContent();
  }
  observeContent();
  document.addEventListener('DOMContentLoaded', observeContent, { once: true });

  window.__mySuperWallSetVisible = function (value) {
    value = Boolean(value);
    if (visible === value) return;
    visible = value;
    if (!visible) {
      frames.forEach(function (frame) {
        if (frame.nativeId !== null) cancel(frame.nativeId);
        frame.nativeId = null;
      });
      pauseContent();
    } else {
      if (document.documentElement) document.documentElement.removeAttribute('data-msw-paused');
      pausedAnimations.forEach(function (animation) {
        if (animation.playState === 'paused') animation.play();
      });
      pausedAnimations.clear();
      pausedMedia.forEach(function (media) {
        if (media.isConnected) {
          var result = media.play();
          if (result && result.catch) result.catch(function () {});
        }
      });
      pausedMedia.clear();
      frames.forEach(function (frame, id) { schedule(id, frame); });
    }
    window.dispatchEvent(new CustomEvent('mysuperwallvisibilitychange', {
      detail: { visible: visible }
    }));
  };
})();
</script>
''';
