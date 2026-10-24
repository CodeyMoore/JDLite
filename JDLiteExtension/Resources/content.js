// Injected into the current page when the JDLite popup opens (activeTab), so no
// per-website permission is needed. It only collects candidate links; popup.js
// decides which ones are download files. Safe to inject more than once.
(() => {
  const api = typeof browser !== "undefined" ? browser : chrome;
  if (globalThis.__jdliteCollector) return;
  globalThis.__jdliteCollector = true;

  const URL_IN_TEXT = /\bhttps?:\/\/[^\s"'<>()\[\]{}]+/gi;
  const clean = s => (s || "").replace(/\s+/g, " ").trim().slice(0, 200);

  function collect() {
    const page = location.href.split("#")[0];
    const out = [];
    const seen = new Set();
    const push = (raw, info) => {
      if (!raw) return;
      let u;
      try { u = new URL(raw, location.href); } catch (e) { return; }
      if (u.protocol !== "http:" && u.protocol !== "https:") return;
      if (u.href.split("#")[0] === page) return; // in-page anchors
      // Keep the #fragment: some hosters (e.g. MEGA) put the file key there.
      if (seen.has(u.href)) return;
      seen.add(u.href);
      out.push(Object.assign({ url: u.href }, info));
    };

    // Ordinary links.
    document.querySelectorAll("a[href], area[href]").forEach(a => {
      push(a.href, {
        text: clean(a.textContent),
        title: clean(a.getAttribute("title") || a.getAttribute("aria-label")),
        download: a.hasAttribute("download") ? (a.getAttribute("download") || "") : null
      });
    });

    // Download buttons that keep their link in a data attribute.
    document.querySelectorAll("[data-download-url], [data-download], [data-href], [data-url], [data-link]").forEach(el => {
      const raw = el.getAttribute("data-download-url") || el.getAttribute("data-download") ||
        el.getAttribute("data-href") || el.getAttribute("data-url") || el.getAttribute("data-link");
      if (raw && /^(https?:)?\/\//i.test(raw.trim())) {
        push(raw.trim(), { text: clean(el.textContent), title: clean(el.getAttribute("title")), download: null });
      }
    });

    // Links written out as plain text (forum posts, code blocks, ...).
    const text = ((document.body && document.body.innerText) || "").slice(0, 500000);
    for (const m of text.matchAll(URL_IN_TEXT)) {
      push(m[0].replace(/[.,;:!?'"]+$/, ""), { text: "", title: "", download: null, plain: true });
    }
    return out;
  }

  api.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (msg && msg.type === "jdlite-collect") {
      sendResponse({ links: collect(), pageURL: location.href });
    }
    return false;
  });
})();
