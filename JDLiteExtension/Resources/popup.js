const api = typeof browser !== "undefined" ? browser : chrome;
const $ = id => document.getElementById(id);

const EXT = {
  files: /\.(zip|rar|7z|tar|gz|tgz|bz2|xz|iso|dmg|pkg|ipa|deb|apk|exe|msi|pdf|epub|mobi|docx?|xlsx?|pptx?|torrent)$/i,
  media: /\.(mp4|m4v|mov|mkv|webm|avi|mp3|m4a|aac|flac|wav|ogg|opus)$/i,
  images: /\.(jpe?g|png|gif|webp|heic|svg|avif)$/i
};
const MAX_URLS = 40; // keeps the jdlite:// URL a sane length

let items = [];
let filter = "files";
const selected = new Set();

function kindOf(url) {
  const path = new URL(url).pathname;
  for (const k of Object.keys(EXT)) if (EXT[k].test(path)) return k;
  return "other";
}

function nameOf(it) {
  try {
    const seg = decodeURIComponent(new URL(it.url).pathname.split("/").filter(Boolean).pop() || "");
    if (seg) return seg;
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

function addHref(urls) {
  return "jdlite://add?" + urls.slice(0, MAX_URLS).map(u => "u=" + encodeURIComponent(u)).join("&");
}

function updateActions() {
  const urls = [...selected];
  const send = $("send");
  send.href = urls.length ? addHref(urls) : "#";
  send.classList.toggle("disabled", urls.length === 0);
  $("count").textContent = urls.length + " selected" + (urls.length > MAX_URLS ? " (first " + MAX_URLS + " sent)" : "");
  const vis = visible();
  $("toggle").textContent = vis.length && vis.every(i => selected.has(i.url)) ? "Select none" : "Select all";
}

async function init() {
  $("q").addEventListener("input", render);
  document.querySelectorAll("#chips button").forEach(b =>
    b.addEventListener("click", () => { filter = b.dataset.filter; render(); }));
  $("toggle").addEventListener("click", () => {
    const vis = visible();
    const all = vis.every(i => selected.has(i.url));
    vis.forEach(i => all ? selected.delete(i.url) : selected.add(i.url));
    render();
  });
  $("copy").addEventListener("click", async () => {
    const urls = [...selected];
    if (!urls.length) return;
    try { await navigator.clipboard.writeText(urls.join("\n")); $("copy").textContent = "Copied"; }
    catch (e) { $("status").textContent = "Couldn't access the clipboard."; }
  });

  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  if (tab && tab.url) $("page").href = "jdlite://add?u=" + encodeURIComponent(tab.url);
  try {
    const res = await api.tabs.sendMessage(tab.id, { type: "collect" });
    items = res.links.map(l => ({ ...l, kind: l.hint || kindOf(l.url) }));
  } catch (e) {
    $("status").textContent = "Couldn't read this page. Allow JDLite on this website in Safari's extension settings.";
    return;
  }
  filter = ["files", "media", "images"].find(k => items.some(i => i.kind === k)) || "all";
  render();
}

init();
