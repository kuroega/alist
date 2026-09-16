// AList selects Artplayer's type from the original filename. Compatible MKVs
// retain that name but serve HLS. Reuse the frontend's bundled HLS module.
(() => {
  "use strict";
  const hlsURL = document.currentScript.dataset.hlsUrl;
  const configured = new WeakMap();
  let library;
  let scheduled = false;

  async function connect() {
    scheduled = false;
    for (const art of window.Artplayer?.instances || []) {
      if (art.isDestroy) continue;
      const source = art.option.url;
      if (!source || configured.get(art) === source) continue;
      let url;
      try { url = new URL(source, document.baseURI); } catch { continue; }
      if (!/\/playback\/[A-Za-z0-9_-]+\/index\.m3u8$/.test(url.pathname)) continue;
      configured.set(art, source);
      try {
        if (!hlsURL) throw new Error("Missing HLS module");
        library ||= import(hlsURL);
        const module = await library;
        const Hls = Object.values(module).find((value) =>
          typeof value === "function" && value.Events?.MANIFEST_PARSED &&
          typeof value.isSupported === "function");
        if (!Hls) throw new Error("Missing HLS constructor");
        if (art.isDestroy || art.option.url !== source) continue;
        let hls;
        art.on("destroy", () => hls?.destroy());
        art.option.customType.m3u8 = (video, stream) => {
          hls?.destroy();
          // Prefer the bundled MSE pipeline. Chromium also advertises native
          // HLS, but that path bypasses our fragment loading policy and can
          // fail in its native demuxer, causing Artplayer to reload from zero.
          if (Hls.isSupported()) {
            hls = new Hls({
              // Segments always contain AAC-LC. Pin its RFC 6381 identifier
              // so hls.js does not infer HE-AAC from incomplete cold data.
              audioCodec: "mp4a.40.2",
              // Cold segments are generated on demand, not pre-existing files.
              // Keep their first-byte budget consistent with the backend's
              // two-minute encoder deadline, without changing other videos.
              fragLoadPolicy: { default: {
                ...Hls.DefaultConfig.fragLoadPolicy.default,
                maxTimeToFirstByteMs: 125000,
                maxLoadTimeMs: 150000,
              } },
              backBufferLength: 30,
              maxBufferLength: 30,
              maxMaxBufferLength: 60,
            });
            hls.on(Hls.Events.ERROR, (_, error) => {
              if (error.fatal) {
                video.pause();
                art.notice.show = "Compatible playback failed or expired. Reopen the file to retry.";
              }
            });
            hls.loadSource(stream);
            hls.attachMedia(video);
          } else if (video.canPlayType("application/vnd.apple.mpegurl")) {
            video.src = stream;
          } else {
            art.notice.show = "This browser cannot play the compatible HLS stream.";
          }
        };
        art.type = "m3u8";
        art.url = source;
      } catch {
        art.notice.show = "Could not load compatible playback. Check the web frontend installation.";
      }
    }
  }

  function schedule() {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(connect);
  }

  const observer = new MutationObserver((records) => {
    if (records.some((record) => record.type === "attributes" ||
      Array.from(record.addedNodes).some((node) => node.nodeType === Node.ELEMENT_NODE &&
        (node.matches("video") || node.querySelector("video"))))) schedule();
  });
  observer.observe(document.documentElement, {
    childList: true, subtree: true, attributes: true, attributeFilter: ["src"],
  });
  schedule();
})();
