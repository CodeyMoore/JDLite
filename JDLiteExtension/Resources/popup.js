const api = typeof browser !== "undefined" ? browser : chrome;
const $ = id => document.getElementById(id);

const EXT = {
  files: /\.(zip|rar|7z|tar|gz|tgz|bz2|xz|iso|dmg|pkg|ipa|deb|apk|exe|msi|pdf|epub|mobi|docx?|xlsx?|pptx?|torrent)$/i,
  media: /\.(mp4|m4v|mov|mkv|webm|avi|mp3|m4a|aac|flac|wav|ogg|opus)$/i,
  images: /\.(jpe?g|png|gif|webp|heic|svg|avif)$/i
};
// Well-known file hosters. Their links are web pages, which the app sends
// through TorBox. This list only groups links here; the app checks TorBox's
// live list of supported sites.
const HOSTERS = [
  "rapidgator.net", "rg.to", "nitroflare.com", "nitro.download", "1fichier.com",
  "ddownload.com", "ddl.to", "katfile.com", "turbobit.net", "hitfile.net",
  "mega.nz", "mediafire.com", "uploadgig.com", "filefactory.com", "fikper.com",
  "gofile.io", "pixeldrain.com", "krakenfiles.com", "send.cm", "usersdrive.com"
];
const ORDER = ["hosters", "files", "media", "images"];
const MAX_URLS = 40; // keeps the jdlite:// link a sane length

let items = [];
let filter = "all";
const selected = new Set();

function kindOf(url) {
  const u = new URL(url);
  const host = u.hostname.toLowerCase().replace(/^www\./, "");
  const hasTarget = u.pathname.length > 1 || u.search.length > 1;
  if (hasTarget && HOSTERS.some(h => host === h || host.endsWith("." + h))) return "hosters";
  const path = u.pathname.replace(/\.html?$/i, ""); // e.g. name.rar.html
  for (const k of ["files", "media", "images"]) if (EXT[k].test(path)) return k;
  return "other";
}

function nameOf(it) {
  try {
    const seg = decodeURIComponent(new URL(it.url).pathname.split("/").filter(Boolean).pop() || "");
    if (seg) return seg.replace(/\.html?$/i, "");
  } catch (e) {}
  return it.label || it.url;
}

function visible() {
  const q = $("q").value.trim().toLowerCase();
  return items.filter(i =>
    (filter === "all" || i.kind === filter) &&
    (!q || (i.url + " " + i.label).toLowerCase().includes(q)));
}

function render() {
  const list = visible();
  const ul = $("list");
  ul.textContent = "";
  document.querySelectorAll("#chips button").forEach(b => {
    const f = b.dataset.filter;
    const n = f === "all" ? items.length : items.filter(i => i.kind === f).length;
    b.textContent = f[0].toUpperCase() + f.slice(1) + " " + n;
    b.classList.toggle("on", f === filter);
  });
  list.forEach(it => {
    const li = document.createElement("li");
    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.checked = selected.has(it.url);
    cb.addEventListener("change", () => {
      cb.checked ? selected.add(it.url) : selected.delete(it.url);
      updateActions();
    });
    const t = document.createElement("div");
    t.className = "t";
    const n = document.createElement("span");
    n.className = "n";
    n.textContent = nameOf(it);
    const h = document.createElement("span");
    h.className = "h";
    h.textContent = new URL(it.url).host;
    t.append(n, h);
    li.append(cb, t);
    ul.append(li);
  });
  $("status").textContent = list.length ? "" : "No matching links on this page.";
  updateActions();
}

function appLink(urls) {
  return "jdlite://add?" + urls.slice(0, MAX_URLS).map(u => "u=" + encodeURIComponent(u)).join("&");
}

function updateActions() {
  const urls = [...selected];
  const send = $("send");
  send.href = urls.length ? appLink(urls) : "#";
  send.classList.toggle("disabled", urls.length === 0);
  $("count").textContent = urls.length + " selected" + (urls.length > MAX_URLS ? " (first " + MAX_URLS + " sent)" : "");
  const vis = visible();
  $("toggle").textContent = vis.length && vis.every(i => selected.has(i.url)) ? "Select none" : "Select all";
}

function setPageLink(url) {
  if (!url || !/^https?:/i.test(url)) return;
  const a = $("page");
  a.href = appLink([url]);
  a.hidden = false;
}

// Opening JDLite from Safari's menu grants access to this one page (activeTab),
// so inject the collector and ask it for the links.
async function readPage(tabId) {
  await api.scripting.executeScript({ target: { tabId }, files: ["content.js"] });
  return api.tabs.sendMessage(tabId, { type: "jdlite-collect" });
}

async function init() {
  $("q").addEventListener("input", render);
  document.querySelectorAll("#chips button").forEach(b =>
    b.addEventListener("click", () => { filter = b.dataset.filter; render(); }));
  $("toggle").addEventListener("click", () => {
    const vis = visible();
    const all = vis.length > 0 && vis.every(i => selected.has(i.url));
    vis.forEach(i => all ? selected.delete(i.url) : selected.add(i.url));
    render();
  });
  $("copy").addEventListener("click", async () => {
    const urls = [...selected];
    if (!urls.length) return;
    try { await navigator.clipboard.writeText(urls.join("\n")); $("copy").textContent = "Copied"; }
    catch (e) { $("status").textContent = "Couldn't access the clipboard."; }
  });

  let tab = null;
  try {
    const tabs = await api.tabs.query({ active: true, currentWindow: true });
    tab = tabs && tabs[0];
  } catch (e) {}
  if (!tab) { $("status").textContent = "No page is open."; return; }
  setPageLink(tab.url);

  let res;
  try {
    res = await readPage(tab.id);
  } catch (e) {
    $("status").textContent = "JDLite couldn't read this page (" + ((e && e.message) || e) +
      "). Start pages and Safari's own pages can't be read.";
    return;
  }
  if (res && res.pageURL) setPageLink(res.pageURL);
  items = ((res && res.links) || []).map(l => ({ ...l, kind: l.hint || kindOf(l.url) }));
  filter = ORDER.find(k => items.some(i => i.kind === k)) || "all";
  render();
}

init();
