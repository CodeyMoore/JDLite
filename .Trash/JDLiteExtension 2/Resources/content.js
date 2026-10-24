const api = typeof browser !== "undefined" ? browser : chrome;

function collect() {
  const found = new Map();
  const add = (raw, label, hint) => {
    if (!raw) return;
    let u;
    try { u = new URL(raw, location.href); } catch (e) { return; }
    if (u.protocol !== "http:" && u.protocol !== "https:") return;
    u.hash = "";
    if (!found.has(u.href)) found.set(u.href, { url: u.href, label: (label || "").trim().slice(0, 80), hint: hint || null });
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
  if (msg && msg.type === "collect") {
    sendResponse({ links: collect(), title: document.title });
  }
  return false;
});
