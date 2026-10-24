const api = typeof browser !== "undefined" ? browser : chrome;
const $ = id => document.getElementById(id);
const MAX_URLS = 40; // keeps the jdlite:// link a sane length

// File types that count as downloads: archives, disk images, apps/installers,
// documents, torrents and ROMs. Images, video/audio, web pages and page assets don't.
const FILE_EXT = new Set((
  "zip rar 7z tar gz tgz bz2 tbz tbz2 xz txz zst lz lzma cab arj lzh ace " +
  "iso img dmg vhd vhdx vmdk qcow2 wim bin cue nrg mdf mds " +
  "exe msi msix msixbundle appx appxbundle appimage deb rpm pkg apk xapk apks apkm aab ipa tipa jar " +
  "pdf epub mobi azw azw3 djvu cbz cbr cb7 doc docx xls xlsx ppt pptx odt ods odp rtf " +
  "torrent nsp nsz xci cia 3ds nds gba sfc smc z64 n64 chd pbp rvz wbfs " +
  "ttf otf blend stl 3mf"
).split(/\s+/));
const IMAGE_EXT = /\.(?:jpe?g|png|gif|webp|avif|heic|heif|bmp|svg|ico|tiff?)$/i;
const PAGE_SUFFIX = /\.(?:s?html?|php\d?|aspx?|jsp|cgi)$/i;

function safeDecode(s) { try { return decodeURIComponent(s); } catch (e) { return s; } }

/** The download-file extension of a name, or null. Handles .tar.gz and split archives. */
function fileExt(name) {
  const n = (name || "").trim().toLowerCase();
  if (!n || IMAGE_EXT.test(n)) return null;
  let m = n.match(/\.(tar\.(?:gz|bz2|xz|zst))$/);
  if (m) return m[1];
  if (/\.(?:r\d{2}|z\d{2})$/.test(n)) return n.slice(-3);     // movie.r00, archive.z01
  if (/\.[a-z0-9]{2,5}\.\d{3}$/.test(n)) return n.slice(-3);  // movie.7z.001
  m = n.match(/\.([a-z0-9]{1,10})$/);
  return m && FILE_EXT.has(m[1]) ? m[1] : null;
}

/** The file name a URL points to, or null when it looks like a web page. */
function nameFromURL(u) {
  const segs = u.pathname.split("/").filter(Boolean).map(safeDecode);
  let seg = segs.pop() || "";
  // e.g. sourceforge.net/projects/x/files/app-1.0.zip/download
  if (/^(?:download|dl|get)$/i.test(seg) && segs.length) seg = segs.pop();
  if (PAGE_SUFFIX.test(seg)) {
    // File-hoster pages often add ".html" after the real name: movie.part1.rar.html
    const inner = seg.replace(PAGE_SUFFIX, "");
    if (fileExt(inner)) return inner;
  } else if (fileExt(seg)) {
    return seg;
  }
  // Name carried in the query string: download.php?file=app.zip, S3 content-disposition, ...
  for (const [, value] of u.searchParams) {
    const cd = value.match(/filename\*?=(?:UTF-8'')?"?([^";]+)"?/i);
    if (cd && fileExt(safeDecode(cd[1]))) return safeDecode(cd[1]);
    const tail = value.split(/[\/\\]/).pop();
    if (tail && fileExt(tail)) return tail;
  }
  return null;
}

/** Link text or a title that is itself a file name, e.g. "Movie.2024.part1.rar". */
function nameFromText(t) {
  const s = (t || "").replace(/\s+/g, " ").trim();
  if (!s || s.length > 180 || /[\/\\<>|*"]/.test(s)) return null;
  return fileExt(s) ? s : null;
}

/** Decides whether a collected link is a download file: {url, name, ext, host} or null. */
function classify(c) {
  let u;
  try { u = new URL(c.url); } catch (e) { return null; }
  if (u.protocol !== "http:" && u.protocol !== "https:") return null;
  if (IMAGE_EXT.test(u.pathname)) return null;
  let name = nameFromURL(u);
  if (!name && !c.plain) name = nameFromText(c.text) || nameFromText(c.title);
  if (!name && typeof c.download === "string") {
    // <a download>: the site says this is a file, even without a recognisable name.
    const d = c.download.trim();
    if (!d) name = safeDecode(u.pathname.split("/").filter(Boolean).pop() || "") || u.hostname;
    else if (!IMAGE_EXT.test(d)) name = d;
  }
  if (!name) return null;
  return { url: u.href, name, ext: fileExt(name) || "", host: u.hostname.replace(/^www\./, "") };
}

let files = [];
const selected = new Set();

function visible() {
  const q = $("q").value.trim().toLowerCase();
  return q ? files.filter(f => (f.name + " " + f.host).toLowerCase().includes(q)) : files;
}

function showMessage(text) { $("message").textContent = text; }

function render() {
  const list = visible();
  const ul = $("list");
  ul.textContent = "";
  for (const f of list) {
    const li = document.createElement("li");
    const label = document.createElement("label");
    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.checked = selected.has(f.url);
    cb.addEventListener("change", () => {
      cb.checked ? selected.add(f.url) : selected.delete(f.url);
      updateActions();
    });
    const t = document.createElement("div");
    t.className = "t";
    const n = document.createElement("span");
    n.className = "n";
    n.textContent = f.name;
    const h = document.createElement("span");
    h.className = "h";
    if (f.ext) {
      const b = document.createElement("b");
      b.className = "ext";
      b.textContent = f.ext.toUpperCase();
      h.append(b);
    }
    h.append(document.createTextNode(f.host));
    t.append(n, h);
    label.append(cb, t);
    li.append(label);
    ul.append(li);
  }
  const count = files.length;
  $("summary").textContent = count ? count + (count === 1 ? " file" : " files") : "";
  $("q").hidden = count < 8; // the filter box only helps on longer lists
  $("actions").hidden = count === 0;
  showMessage(count === 0 ? "No download files found on this page." : (list.length ? "" : "No files match your filter."));
  updateActions();
}

function appLink(urls) {
  return "jdlite://add?" + urls.slice(0, MAX_URLS).map(u => "u=" + encodeURIComponent(u)).join("&");
}

function chosenURLs() { return files.filter(f => selected.has(f.url)).map(f => f.url); }

function updateActions() {
  const urls = chosenURLs();
  const send = $("send");
  send.href = urls.length ? appLink(urls) : "#";
  send.classList.toggle("disabled", urls.length === 0);
  send.textContent = urls.length > 1 ? "Send " + Math.min(urls.length, MAX_URLS) + " to JDLite" : "Send to JDLite";
  $("count").textContent = urls.length + " selected" + (urls.length > MAX_URLS ? " (first " + MAX_URLS + " sent)" : "");
  const vis = visible();
  $("toggle").textContent = vis.length && vis.every(f => selected.has(f.url)) ? "Select none" : "Select all";
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
  $("toggle").addEventListener("click", () => {
    const vis = visible();
    const all = vis.length > 0 && vis.every(f => selected.has(f.url));
    vis.forEach(f => all ? selected.delete(f.url) : selected.add(f.url));
    render();
  });
  $("copy").addEventListener("click", async () => {
    const urls = chosenURLs();
    if (!urls.length) return;
    try { await navigator.clipboard.writeText(urls.join("\n")); $("copy").textContent = "Copied"; }
    catch (e) { showMessage("Couldn't access the clipboard."); }
  });

  let tab = null;
  try {
    const tabs = await api.tabs.query({ active: true, currentWindow: true });
    tab = tabs && tabs[0];
  } catch (e) {}
  if (!tab) { showMessage("No page is open."); return; }
  setPageLink(tab.url);

  let res;
  try {
    res = await readPage(tab.id);
  } catch (e) {
    showMessage("JDLite couldn't read this page (" + ((e && e.message) || e) +
      "). Start pages and Safari's own pages can't be read.");
    return;
  }
  if (res && res.pageURL) setPageLink(res.pageURL);
  const seen = new Set();
  files = [];
  for (const c of (res && res.links) || []) {
    const f = classify(c);
    if (f && !seen.has(f.url)) { seen.add(f.url); files.push(f); }
  }
  files.forEach(f => selected.add(f.url)); // everything found starts selected
  render();
}

init();
