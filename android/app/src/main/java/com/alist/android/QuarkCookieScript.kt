package com.alist.android

internal const val QUARK_COOKIE_SCRIPT = """
    (function() {
      if (window.__alistAndroidQuarkCookieInstalled) return;
      window.__alistAndroidQuarkCookieInstalled = true;

      var buttonId = "alist-android-quark-cookie";
      var pendingCookie = typeof window.__alistAndroidQuarkCookiePending === "string"
        ? window.__alistAndroidQuarkCookiePending : "";
      var filledCookie = "";
      delete window.__alistAndroidQuarkCookiePending;

      function getDriverText() {
        var driver = document.getElementById("driver") ||
          document.getElementById("driver-trigger");
        if (!driver) return "";
        var values = [
          driver.value || "",
          driver.textContent || "",
          driver.getAttribute("aria-label") || "",
          driver.getAttribute("data-value") || ""
        ];
        var descendants = driver.querySelectorAll("input, [value]");
        for (var index = 0; index < descendants.length; index += 1) {
          values.push(descendants[index].value || "");
          values.push(descendants[index].getAttribute("value") || "");
        }
        return values.join(" ");
      }

      function isQuarkDriver() {
        var driverText = getDriverText();
        if (/quark\s*tv|夸克\s*tv/i.test(driverText)) return false;
        return /quark|夸克/i.test(driverText);
      }

      function removeButton() {
        var button = document.getElementById(buttonId);
        if (button && button.parentNode) button.parentNode.removeChild(button);
      }

      function setFieldValue(field, value) {
        var prototype = Object.getPrototypeOf(field);
        var descriptor = prototype && Object.getOwnPropertyDescriptor(prototype, "value");
        if (descriptor && descriptor.set) {
          descriptor.set.call(field, value);
        } else {
          field.value = value;
        }
        field.dispatchEvent(new Event("input", { bubbles: true }));
        field.dispatchEvent(new Event("change", { bubbles: true }));
      }

      function createButton(field) {
        var button = document.createElement("button");
        button.id = buttonId;
        button.type = "button";
        button.textContent = "从夸克网页获取 Cookie";
        button.setAttribute("aria-label", "从夸克网页获取 Cookie");
        button.style.cssText =
          "display:block;margin-top:8px;padding:6px 12px;cursor:pointer;";
        button.__alistAndroidQuarkCookieField = field;
        button.addEventListener("click", function(event) {
          event.preventDefault();
          event.stopPropagation();
          if (window.AlistAndroid &&
              typeof window.AlistAndroid.openQuarkCookieLogin === "function") {
            window.AlistAndroid.openQuarkCookieLogin();
          }
        });
        field.insertAdjacentElement("afterend", button);
        return button;
      }

      function synchronize() {
        var button = document.getElementById(buttonId);
        if (!isQuarkDriver()) {
          removeButton();
          return;
        }
        var field = document.getElementById("cookie");
        if (!field) {
          removeButton();
          return;
        }
        if (!button || button.__alistAndroidQuarkCookieField !== field) {
          removeButton();
          button = createButton(field);
        }
        if (pendingCookie) {
          var cookie = pendingCookie;
          pendingCookie = "";
          setFieldValue(field, cookie);
          filledCookie = cookie;
        }
        if (filledCookie && field.value === filledCookie) {
          if (button.textContent !== "已填入 Cookie") {
            button.textContent = "已填入 Cookie";
          }
          if (button.getAttribute("aria-label") !== "已填入 Cookie") {
            button.setAttribute("aria-label", "已填入 Cookie");
          }
        }
      }
      window.__alistAndroidQuarkCookieReady = function(cookie) {
        if (typeof cookie !== "string" || !cookie) return;
        pendingCookie = cookie;
        synchronize();
      };

      if (document.documentElement) {
        new MutationObserver(synchronize).observe(document.documentElement, {
          childList: true,
          subtree: true,
          attributes: true
        });
      }
      window.setInterval(synchronize, 500);
      synchronize();
    })();
"""
