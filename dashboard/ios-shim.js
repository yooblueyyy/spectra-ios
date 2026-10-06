/*
 * Spectra for iOS: gives the shared dashboard the storage/messaging API it uses in the browser
 * extension, desktop and Android apps, backed by the tweak's "spectra" message handler (only the
 * dashboard's own web view has it). Injected at document start by Spectra/Dashboard.m.
 *
 * The iPhone app shows the dashboard's Extensions, Snippets and Admin (with Settings, where Discord is
 * linked for Admin). Spotify for iOS is a native app, so web extensions and CSS snippets installed here
 * are kept with your Spectra setup and apply in Spectra on the web, desktop and Quest.
 */
(function () {
  "use strict";
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.spectra;
  if (!handler) return;
  const listeners = new Set();
  const call = (message) => handler.postMessage(message).then((reply) => {
    try { return reply ? JSON.parse(reply) : {}; } catch { return {}; }
  });

  // Called by the native side whenever stored settings change.
  window.__spectraStorageChanged = function (changes) {
    for (const fn of listeners) { try { fn(changes, "local"); } catch (e) { console.error(e); } }
  };

  window.spectraHost = {
    storage: {
      local: {
        get: (keys) => call({ op: "get", keys: keys == null ? null : keys }),
        set: (obj) => call({ op: "set", obj: obj || {} }).then(() => undefined),
      },
      onChanged: { addListener: (fn) => { listeners.add(fn); } },
    },
    runtime: {
      spectraApp: true,
      platform: "ios",
      sendMessage: (msg) => call({ op: "send", msg: msg || {} }),
      getURL: (p) => p,
    },
    permissions: { contains: async () => true, request: async () => true },
  };

  const VIEWS = ["extensions", "snippets", "admin", "settings"];
  const style = document.createElement("style");
  style.textContent = [
    ".nav button[data-view]:not(" + VIEWS.map((v) => `[data-view="${v}"]`).join("):not(") + ") { display: none !important; }",
    ".sidebar-foot .master, .sidebar-foot #reload-tabs { display: none !important; }",
    ".sidebar { padding-top: max(8px, env(safe-area-inset-top)) !important; }",
    ".is-ios .ios-note { margin: 0 0 16px; padding: 12px 14px; border-radius: 12px; background: rgba(255,255,255,.05); font-size: 13px; color: var(--text-2, #b3b3b3); }",
  ].join("\n");
  document.documentElement.classList.add("is-app", "is-ios");
  document.addEventListener("DOMContentLoaded", () => {
    document.head.appendChild(style);
    for (const view of ["extensions", "snippets"]) {
      const section = document.querySelector(`.view[data-view="${view}"]`);
      if (!section) continue;
      const note = document.createElement("p");
      note.className = "ios-note";
      note.textContent = "Spotify on iPhone is a native app, so " + view + " don't run inside it. What you install here is saved with your Spectra setup for Spectra on the web, desktop and Quest; use Settings > Export to move it there.";
      section.insertBefore(note, section.children[1] || null);
    }
    const name = (location.hash || "").slice(1).split(":")[0];
    if (!VIEWS.includes(name)) location.hash = "#extensions";
  });
})();
