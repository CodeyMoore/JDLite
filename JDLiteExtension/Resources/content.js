// JDLite page scanner. Injected into the page and its frames when the JDLite popup opens
// (activeTab), so no per-site permission is needed. It collects every link that could be a
// download — popup.js decides which ones are files — and, when asked, checks links on this
// site to see whether they lead to a file. Safe to inject more than once.
(() => {
  const api = typeof browser !== "undefined" ? browser : chrome;
  const VERSION = 3;
  if (globalThis.__jdliteScanner === VERSION) return;
  globalThis.__jdliteScanner = VERSION;

  const URL_IN_TEXT = /\bhttps?:\/\/[^\s"'<>()\[\]{}`|^\\]+/gi;
  const MAGNET_IN_TEXT = /\bmagnet:\?[^\s"'<>`]+/gi;
  // Root-relative paths to files inside code, e.g. location.href = "/files/app-2.1.zip"
  const PATH_IN_CODE = /["'`](\/[^"'`\s<>]{1,400}?\.[a-z0-9]{1,8}(?:\?[^"'`\s<>]{0,400})?)["'`]/gi;
  const DOWNLOAD_WORDS = /\b(?:download|downloads|dl|direct link|get (?:the )?file|mirror|herunterladen|t[ée]l[ée]charger|descargar|scarica|baixar|pobierz|indir|downloaden|ladda ner)\b|скачать|завантажити|下载|下載|ダウンロード|다운로드|تحميل/i;
  const DOWNLOAD_MARKS = /download|(?:^|[\s_-])dl(?:[\s_-]|$)|dlbutton|btn-dl/;
  // Pictures, players and page furniture aren't downloads.
  const MEDIA_TAGS = new Set(["IMG", "PICTURE", "VIDEO", "AUDIO", "SOURCE", "TRACK", "LINK", "STYLE", "SVG"]);
  const URL_ATTRS = new Set(["href", "formaction", "to", "ng-href", "action", "value"]);
  const TEXT_BUDGET = 1_500_000;
  const CODE_BUDGET = 2_000_000;

  const clean = s => (s || "").replace(/\s+/g, " ").trim().slice(0, 200);
  const trimURL = s => s.replace(/[.,;:!?'")\]}>]+$/, "");

  function classOf(el) {
    const c = el.className;
    return typeof c === "string" ? c : (el.getAttribute && el.getAttribute("class")) || "";
  }

  /** The element, or something just around it, says "download". */
  function looksLikeDownload(el) {
    for (let e = el, depth = 0; e && e.nodeType === 1 && depth < 4; e = e.parentElement, depth++) {
      if (DOWNLOAD_MARKS.test(((e.id || "") + " " + classOf(e)).toLowerCase())) return true;
    }
    const words = clean(el.textContent) + " " + (el.getAttribute("title") || "") + " " +
      (el.getAttribute("aria-label") || "") + " " + (el.getAttribute("value") || "");
    return DOWNLOAD_WORDS.test(words);
  }

  function looksLikeURL(v) {
    return /^(?:https?:)?\/\//i.test(v) || /^\/[^\/\s]/.test(v) ||
      (/^[^\s:]+\.[a-z0-9]{2,6}(?:[?#].*)?$/i.test(v) && v.includes("/"));
  }

  function collect() {
    const base = document.baseURI || location.href;
    const page = location.href.split("#")[0];
    const links = [];
    const index = new Map();
    let textLeft = TEXT_BUDGET;
    let codeLeft = CODE_BUDGET;

    const add = (raw, info) => {
      if (!raw || typeof raw !== "string") return;
      raw = raw.trim();
      if (!raw || raw.length > 4000) return;
      let u;
      try { u = new URL(raw, base); } catch (e) { return; }
      if (u.protocol !== "http:" && u.protocol !== "https:" && u.protocol !== "magnet:") return;   // magnet: torrents
      if (u.href.split("#")[0] === page && info.source !== "self") return;   // links within this page
      // Keep the #fragment: some hosters (e.g. MEGA) put the file key there.
      const at = index.get(u.href);
      if (at !== undefined) {
        // Found again: keep the most useful details.
        const p = links[at];
        if (!p.text && info.text) p.text = info.text;
        if (!p.title && info.title) p.title = info.title;
        if (p.download == null && info.download != null) p.download = info.download;
        p.hint = p.hint || !!info.hint;
        if (rank(info.source) > rank(p.source)) p.source = info.source;
        return;
      }
      index.set(u.href, links.length);
      links.push({
        url: u.href,
        text: info.text || "",
        title: info.title || "",
        download: info.download == null ? null : info.download,
        hint: !!info.hint,
        source: info.source
      });
    };

    const scanText = text => {
      if (!text || textLeft <= 0) return;
      text = text.slice(0, textLeft);
      textLeft -= text.length;
      for (const m of text.matchAll(URL_IN_TEXT)) add(trimURL(m[0]), { source: "text" });
      for (const m of text.matchAll(MAGNET_IN_TEXT)) add(trimURL(m[0]), { source: "text" });
    };

    const scanCode = (code, source, hint) => {
      if (!code || codeLeft <= 0) return;
      code = code.slice(0, codeLeft);
      codeLeft -= code.length;
      // Undo JSON/JS escaping: https:\/\/example.com\/file.zip
      code = code.replace(/\\u002[fF]/g, "/").replace(/\\\//g, "/");
      for (const m of code.matchAll(URL_IN_TEXT)) add(trimURL(m[0]), { source, hint });
      for (const m of code.matchAll(MAGNET_IN_TEXT)) add(trimURL(m[0]), { source, hint });
      for (const m of code.matchAll(PATH_IN_CODE)) add(m[1], { source, hint });
    };

    const scanElement = el => {
      const tag = el.tagName.toUpperCase();   // SVG elements have lower-case tag names
      if (tag === "A" || tag === "AREA") {
        const href = el.getAttribute("href");
        if (href && !/^\s*(?:javascript:|mailto:|tel:|sms:|#)/i.test(href)) {
          add(href, {
            text: clean(el.textContent),
            title: clean(el.getAttribute("title") || el.getAttribute("aria-label")),
            download: el.hasAttribute("download") ? (el.getAttribute("download") || "") : null,
            hint: looksLikeDownload(el),
            source: "link"
          });
        } else if (href && /^\s*javascript:/i.test(href)) {
          scanCode(href, "click", looksLikeDownload(el));
        }
      }
      if (tag === "SCRIPT") {
        if (!el.src) scanCode(el.textContent, "script", false);
        return;
      }
      if (tag === "NOSCRIPT") scanText(el.textContent);   // fallback links for pages without JavaScript
      if (MEDIA_TAGS.has(tag)) return;
      if (tag === "IFRAME" || tag === "FRAME" || tag === "EMBED") {
        const src = el.getAttribute("src");
        if (src) add(src, { source: "frame" });
      } else if (tag === "OBJECT") {
        const data = el.getAttribute("data");
        if (data) add(data, { source: "frame" });
      } else if (tag === "META" && /refresh/i.test(el.getAttribute("http-equiv") || "")) {
        // "Your download will start in 5 seconds" pages
        const m = (el.getAttribute("content") || "").match(/url\s*=\s*['"]?([^'";]+)/i);
        if (m) add(m[1], { source: "refresh", hint: true });
      } else if (tag === "INPUT" || tag === "TEXTAREA") {
        if (el.type !== "password" && el.type !== "hidden") scanText(el.value);   // "copy this link" boxes
      }
      // Buttons and other elements that keep their link in an attribute or a click handler.
      let hint = null;
      for (const attr of el.attributes) {
        const name = attr.name.toLowerCase();
        const value = attr.value;
        if (!value) continue;
        if (name.startsWith("on")) {
          if (/https?:|\//.test(value)) scanCode(value, "click", hint ?? (hint = looksLikeDownload(el)));
          continue;
        }
        if (tag === "A" || tag === "AREA") continue;   // handled above
        if (!(name.startsWith("data-") || URL_ATTRS.has(name))) continue;
        if (name === "action" && (tag !== "FORM" || (el.getAttribute("method") || "get").toLowerCase() !== "get")) continue;
        const v = value.trim();
        if (v.length > 4000) continue;
        if (looksLikeURL(v)) {
          add(v, { text: clean(el.textContent), title: clean(el.getAttribute("title")), hint: hint ?? (hint = looksLikeDownload(el)), source: "attr" });
        } else if (name.startsWith("data-") && /https?:\/\//i.test(v)) {
          scanCode(v, "attr", hint ?? (hint = looksLikeDownload(el)));   // JSON in a data attribute
        }
      }
    };

    // Walk the page, including open shadow roots (web components), elements first, then text.
    const roots = [document];
    for (let r = 0; r < roots.length && r < 500; r++) {
      const root = roots[r];
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
      for (let el = walker.nextNode(); el; el = walker.nextNode()) {
        scanElement(el);
        if (el.shadowRoot) roots.push(el.shadowRoot);
      }
    }
    // Links written out as plain text (forum posts, code blocks, spoilers that are still hidden).
    for (let r = 0; r < roots.length && r < 500 && textLeft > 0; r++) {
      const walker = document.createTreeWalker(roots[r], NodeFilter.SHOW_TEXT, {
        acceptNode: n => {
          const p = n.parentNode && n.parentNode.nodeName;
          return p === "SCRIPT" || p === "STYLE" || p === "NOSCRIPT" || p === "TEXTAREA"
            ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
        }
      });
      let chunk = "";
      for (let n = walker.nextNode(); n; n = walker.nextNode()) {
        if (!/https?:|magnet:/i.test(n.nodeValue)) continue;
        chunk += n.nodeValue + "\n";
        if (chunk.length > 65536) { scanText(chunk); chunk = ""; }
      }
      scanText(chunk);
    }
    // The page itself may be the file (a PDF, a video or a text file opened in Safari).
    add(location.href, { source: "self" });
    return {
      links,
      pageURL: location.href,
      origin: location.origin,
      top: window === window.top,
      contentType: document.contentType || ""
    };
  }

  function rank(source) {
    return { link: 5, attr: 4, refresh: 4, click: 3, frame: 2, text: 1, script: 0, self: 0 }[source] ?? 0;
  }

  /** Asks the server what a link on this site leads to, without downloading it. */
  async function inspect(url) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 6000);
    let same = false;
    try { same = new URL(url, location.href).origin === location.origin; } catch (e) {}
    const opts = { cache: "no-store", credentials: same ? "include" : "omit", redirect: "follow", signal: ctrl.signal };
    try {
      let res = await fetch(url, Object.assign({ method: "HEAD" }, opts));
      if (res.status === 403 || res.status === 405 || res.status === 501) {
        // Some servers refuse HEAD: ask for the first byte instead.
        res = await fetch(url, Object.assign({ method: "GET", headers: { Range: "bytes=0-0" } }, opts));
      }
      const h = res.headers;
      const info = {
        url,
        status: res.status,
        finalURL: res.url || url,
        type: h.get("content-type") || "",
        disposition: h.get("content-disposition") || "",
        length: h.get("content-length") || "",
        range: h.get("content-range") || ""
      };
      ctrl.abort();   // the headers are all that's needed
      return info;
    } catch (e) {
      return { url, error: String((e && e.message) || e) };
    } finally {
      clearTimeout(timer);
    }
  }

  async function inspectAll(urls) {
    const list = urls.slice(0, 40);
    const results = new Array(list.length);
    let next = 0;
    const worker = async () => {
      while (next < list.length) {
        const i = next++;
        results[i] = await inspect(list[i]);
      }
    };
    await Promise.all(Array.from({ length: Math.min(6, list.length) }, worker));
    return results;
  }

  api.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (!msg) return false;
    if (msg.type === "jdlite-collect-3") {
      try { sendResponse(collect()); } catch (e) { sendResponse({ links: [], error: String(e) }); }
      return false;
    }
    if (msg.type === "jdlite-check-3" && Array.isArray(msg.urls)) {
      inspectAll(msg.urls).then(results => sendResponse({ results }), () => sendResponse({ results: [] }));
      return true;   // answers later
    }
    return false;
  });
})();
