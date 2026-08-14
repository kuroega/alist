package com.alist.android

internal const val EXTERNAL_PLAYBACK_SCRIPT = """
    (function() {
      if (window.__alistAndroidExternalPlaybackInstalled) return;
      window.__alistAndroidExternalPlaybackInstalled = true;

      var overlay;
      var button;
      var activeVideo;
      var compactVideoControlsClass = "alist-android-compact-video-controls";
      var compactVideoControlsStyleId = "alist-android-compact-video-controls-style";

      function ensureCompactVideoControlsStyle() {
        if (document.getElementById(compactVideoControlsStyleId)) return;
        var style = document.createElement("style");
        style.id = compactVideoControlsStyleId;
        style.textContent =
          ".art-video-player." + compactVideoControlsClass +
          " .art-control-setting," +
          ".art-video-player." + compactVideoControlsClass +
          " .art-control-pip{display:none !important;}";
        (document.head || document.documentElement).appendChild(style);
      }

      function updateCompactVideoControls() {
        ensureCompactVideoControlsStyle();
        var players = Array.prototype.slice.call(
          document.querySelectorAll(".art-video-player")
        );
        players.forEach(function(player) {
          var fullscreen = player.querySelector(".art-control-fullscreen");
          var controls = player.querySelector(".art-controls");
          if (!fullscreen || !controls) {
            player.classList.remove(compactVideoControlsClass);
            return;
          }
          player.classList.remove(compactVideoControlsClass);
          var playerRect = player.getBoundingClientRect();
          var fullscreenRect = fullscreen.getBoundingClientRect();
          var overflow = fullscreenRect.right > playerRect.right + 1 ||
            fullscreenRect.left < playerRect.left - 1;
          player.classList.toggle(compactVideoControlsClass, overflow);
        });
      }

      function ensureControls() {
        if (overlay && overlay.parentNode) return;
        overlay = document.createElement("div");
        overlay.id = "alist-android-external-playback";
        overlay.style.cssText =
          "display:none;position:fixed;right:16px;bottom:88px;z-index:2147483647;";
        button = document.createElement("button");
        button.type = "button";
        button.textContent = "外部播放";
        button.setAttribute("aria-label", "外部播放");
        button.style.cssText =
          "border:0;border-radius:18px;padding:8px 14px;background:rgba(20,20,20,.82);" +
          "color:#fff;font-size:14px;box-shadow:0 2px 8px rgba(0,0,0,.35);";
        button.addEventListener("click", function(event) {
          event.preventDefault();
          event.stopPropagation();
          if (!activeVideo || !window.AlistAndroid ||
              !window.AlistAndroid.openExternalPlayer) return;
          var source = getPlayableSource(activeVideo);
          if (!source) return;
          activeVideo.pause();
          var type = activeVideo.getAttribute("type") || "";
          window.AlistAndroid.openExternalPlayer(
            source,
            type,
            "",
            navigator.userAgent || "",
            document.cookie || ""
          );
        });
        overlay.appendChild(button);
        document.documentElement.appendChild(overlay);
      }

      function getPlayableSource(video) {
        var source = video.currentSrc || video.src || "";
        if (source.indexOf("blob:") !== 0 && source) return source;
        var sourceElement = video.querySelector("source[src]");
        if (sourceElement && sourceElement.src &&
            sourceElement.src.indexOf("blob:") !== 0) {
          return sourceElement.src;
        }
        if (!window.performance || !performance.getEntriesByType) return "";
        var entries = performance.getEntriesByType("resource");
        for (var index = entries.length - 1; index >= 0; index -= 1) {
          var candidate = entries[index].name || "";
          if (/\.(m3u8|mp4|m4v|webm|mkv|mov|flv)(?:[?#]|$)/i.test(candidate)) {
            return candidate;
          }
        }
        return "";
      }

      function findVideo() {
        var videos = Array.prototype.slice.call(document.querySelectorAll("video"));
        var visible = videos.filter(function(video) {
          var rect = video.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0;
        });
        return visible[0] || videos[0] || null;
      }

      function updateControls() {
        if (!document.documentElement) return;
        ensureControls();
        updateCompactVideoControls();
        activeVideo = findVideo();
        var source = activeVideo && getPlayableSource(activeVideo);
        overlay.style.display = activeVideo && source ? "block" : "none";
      }

      new MutationObserver(updateControls).observe(document.documentElement, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ["src"]
      });
      window.setInterval(updateControls, 1000);
      document.addEventListener("fullscreenchange", updateControls);
      window.addEventListener("resize", updateControls);
      updateControls();
    })();
"""
