{{flutter_js}}
{{flutter_build_config}}

// Phone demo: local CanvasKit (no gstatic CDN) + no service worker (avoids blank cache).
_flutter.loader.load({
  config: {
    canvasKitBaseUrl: "canvaskit/",
    forceSingleThreadedSkwasm: true,
    suppressMultithreadingWarning: true,
  },
  onEntrypointLoaded: async function (engineInitializer) {
    const el = document.getElementById("loading");
    if (el) el.textContent = "Starting Wamu…";
    const appRunner = await engineInitializer.initializeEngine();
    if (el) el.remove();
    await appRunner.runApp();
  },
});
