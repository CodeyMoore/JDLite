// Injected into the current page when the JDLite popup opens (activeTab),
// so no per-website permission is needed. Safe to inject more than once.
(() => {
  const api = typeof browser !== "undefined" ? browser : chrome;
  if (globalThis.__jdliteCollector) return;
  globalThis.__jdliteCollector = true;

  function collect() {
    const page = location.href.split("#")[0];
    const found = new Map();
    const add = (raw, label, hint) => {
      if (!raw) return;
      let u;
      try { u = new URL(raw, location.href); } catch (e) { return; }
      if (u.protocol !== "http:" && u.protocol !== "https:") return;
      if (u.href.split("#")[0] === page) return; // in-page anchors
      // Keep the #fragment: some hosters (e.g. MEGA) put the file key there.
      if (!found.has(u.href)) {
        found.set(u.href, { url: u.href, label: (label || "").trim().slice(0, 80), hint: hint || null });
      }
    };
    document.querySelectorAll("a[href]").forEach(a => add(a.href, a.textContent || a.title));
    document.querySelectorAll("video, audio").forEach(m => {
      add(m.currentSrc || m.src, m.title || "media", "media");
      m.querySelectorAll("source[src]").forEach(s => add(s.src, "media", "media"));
    });
    document.querySelectorAll("img[src]").forEach(i => add(i.currentSrc || i.src, i.alt, "images"));
    return Array.from(found.values());
  }

  api.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (msg && msg.type === "jdlite-collect") {
      sendResponse({ links: collect(), pageURL: location.href });
    }
    return false;
  });
})();
