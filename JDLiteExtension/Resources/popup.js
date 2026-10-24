const api = typeof browser !== "undefined" ? browser : chrome;
const $ = id => document.getElementById(id);
const MAX_URLS = 100;      // links per hand-over to the app
const MAX_LINK = 60000;    // characters in one jdlite:// link
const MAX_CHECKS = 30;     // "download" links checked with the server

// ---- What counts as a download file -------------------------------------------------

const words = s => s.trim().split(/\s+/);
const FILE_EXT = new Set([
  // archives
  ...words("zip zipx rar 7z tar gz tgz bz2 tbz tbz2 xz txz zst lz lz4 lzma cab arj lzh ace sit sitx"),
  // disk images
  ...words("iso img dmg vhd vhdx vmdk qcow2 wim esd swm bin cue nrg mdf mds"),
  // apps, installers and sideloading files
  ...words("exe msi msix msixbundle appx appxbundle appimage deb rpm pkg apk xapk apks apkm aab ipa tipa jar ipsw dylib p12 mobileprovision"),
  // documents and books
  ...words("pdf epub mobi azw azw3 djvu cbz cbr cb7 doc docx xls xlsx ppt pptx odt ods odp rtf csv"),
  // video and audio files that are linked as files (players on the page are ignored)
  ...words("mp4 m4v mkv mov avi wmv flv webm mpg mpeg m2ts mts vob 3gp rmvb ogv"),
  ...words("mp3 m4a m4b flac wav aac ogg oga opus wma aiff aif ape"),
  // subtitles, torrents, game files, fonts, 3D and design files
  ...words("srt ass ssa sub torrent nsp nsz xci cia 3ds nds gba gbc sfc smc z64 n64 chd pbp rvz wbfs cso gcm wad wux wua vpk"),
  ...words("ttf otf blend stl 3mf fbx psd ai eps sketch")
]);
const IMAGE_EXT = /\.(?:jpe?g|png|gif|webp|avif|heic|heif|bmp|svg|ico|tiff?|jxl)$/i;
const PAGE_SUFFIX = /\.(?:s?html?|xhtml|php\d?|aspx?|jsp|cgi)$/i;
const ASSET_EXT = /\.(?:css|js|mjs|json|xml|rss|atom|map|woff2?|wasm|m3u8|mpd|ts|m4s|vtt)$/i;
const TYPE_EXT = {
  "application/zip": "zip", "application/x-zip-compressed": "zip", "application/x-rar-compressed": "rar",
  "application/vnd.rar": "rar", "application/x-7z-compressed": "7z", "application/gzip": "gz",
  "application/pdf": "pdf", "application/x-apple-diskimage": "dmg", "application/vnd.android.package-archive": "apk",
  "application/x-msdownload": "exe", "application/x-iso9660-image": "iso", "application/x-bittorrent": "torrent",
  "video/mp4": "mp4", "video/x-matroska": "mkv", "audio/mpeg": "mp3", "application/epub+zip": "epub"
};

// Not downloads: app stores, social sites and share buttons, link shorteners and protectors.
const NOT_DOWNLOADS = /(?:^|\.)(?:apps\.apple\.com|itunes\.apple\.com|testflight\.apple\.com|play\.google\.com|facebook\.com|fb\.com|twitter\.com|x\.com|instagram\.com|threads\.net|tiktok\.com|youtube\.com|youtu\.be|linkedin\.com|pinterest\.com|reddit\.com|tumblr\.com|vk\.com|discord\.gg|discord\.com|t\.me|telegram\.me|wa\.me|whatsapp\.com|patreon\.com|paypal\.com|paypal\.me|ko-fi\.com|buymeacoffee\.com|filecrypt\.cc|filecrypt\.co|ouo\.io|ouo\.press|linkvertise\.com|shrinkme\.io|shrinke\.me|adf\.ly|exe\.io|keeplinks\.org|bit\.ly|tinyurl\.com)$/i;

// File hosts. Their links are web pages that TorBox downloads from. Links that name the file
// count as files; nameless ones are offered under "Other download links".
const HOSTERS = words(`rapidgator.net rg.to nitroflare.com nitro.download 1fichier.com alterupload.com cjoint.net
  desfichiers.com dfichiers.com megadl.fr mesfichiers.org piecejointe.net pjointe.com tenvoi.com dl4free.com
  ddownload.com ddl.to katfile.com mega.nz mega.co.nz mediafire.com uploaded.net uploaded.to ul.to turbobit.net
  hitfile.net filefactory.com uploadgig.com fikper.com clicknupload.org clicknupload.to clicknupload.click
  drop.download filespace.com usersdrive.com hexload.com hexupload.net send.cm gofile.io pixeldrain.com
  krakenfiles.com buzzheavier.com dropbox.com drive.google.com docs.google.com 4shared.com uptobox.com
  wetransfer.com we.tl uploadhaven.com upload.ee filer.net alfafile.net worldbytez.com vikingfile.com
  mexa.sh filestore.me sendspace.com file.al dailyuploads.net userscloud.com uploadrar.com rapidcloud.cc
  isra.cloud fastupload.io qiwi.gg`);
// Pages on file hosts that aren't files: premium, sign-in, help, ...
const HOSTER_PAGE = /^(?:premium|login|signin|sign-in|register|signup|sign-up|join|faq|help|support|terms|tos|privacy|dmca|contact|about|affiliate|partners?|pricing|plans?|upgrade|blog|news|account|dashboard|settings|api|reseller|tools|article|articles|abuse|copyright|legal|payment|buy|checkout|forgot|reset|profile|cabinet)(?:\.\w+)?$/i;

// Link words and addresses that say "download".
const DOWNLOAD_PATH = /(?:^|[\/_.=&?-])(?:download|downloads|dl|get|getfile|attachment|attachments|file|files|mirror|direct)(?:[\/_.?=&-]|$)/i;
// Redirect links: /out?url=https://host/file.zip goes straight to the file.
const WRAP_KEYS = /^(?:url|u|link|target|goto|to|dest|destination|redirect|redirect_to|redirect_url|out|go|href|q)$/i;
const NAME_IN_TEXT = /[^\s\/\\<>|*"?:()\[\]{}]+\.[a-z0-9]{1,12}(?:\.\d{3})?/gi;
const GENERIC_TEXT = /^(?:download|download now|free download|direct download|download file|download link|mirror(?: \d+)?|get|get it|dl|here|click here|link|open|go)$/i;

function safeDecode(s) { try { return decodeURIComponent(s); } catch (e) { return s; } }
function safeURL(s) { try { return new URL(s); } catch (e) { return null; } }
const clean = s => (s || "").replace(/\s+/g, " ").trim();

/** The download-file extension of a name, or null. Handles .tar.gz and split archives. */
function fileExt(name) {
  const n = (name || "").trim().toLowerCase();
  if (!n || IMAGE_EXT.test(n)) return null;
  let m = n.match(/\.(tar\.(?:gz|bz2|xz|zst|lz4))$/);
  if (m) return m[1];
  if (/[^.\/]\.(?:r\d{2}|z\d{2})$/.test(n)) return n.slice(-3);     // movie.r00, archive.z01
  if (/[^.\/]\.\d{3}$/.test(n)) return n.slice(-3);                  // movie.7z.001, movie.001
  m = n.match(/[^.\/]\.([a-z0-9]{1,12})$/);
  return m && FILE_EXT.has(m[1]) ? m[1] : null;
}

/** The last meaningful part of a link's path, e.g. "app.zip" (skips ".../download"). */
function lastSegment(u) {
  const segs = u.pathname.split("/").filter(Boolean).map(safeDecode);
  let seg = segs.pop() || "";
  if (/^(?:download|dl|get|file|view)$/i.test(seg) && segs.length) seg = segs.pop();
  return seg;
}

/** The file name a link points to, or null when it looks like a web page. */
function nameFromURL(u) {
  if (!u) return null;
  const seg = lastSegment(u);   // also sourceforge .../app.zip/download and mediafire .../app.zip/file
  if (PAGE_SUFFIX.test(seg)) {
    const inner = seg.replace(PAGE_SUFFIX, "");   // file hosts add ".html" after the name
    if (fileExt(inner)) return inner;
  } else if (fileExt(seg)) {
    return seg;
  }
  // The name in the query: download.php?file=app.zip, S3 response-content-disposition, ...
  for (const [, value] of u.searchParams) {
    const cd = value.match(/filename\*?=(?:UTF-8'')?"?([^";]+)"?/i);
    if (cd && fileExt(safeDecode(cd[1]))) return safeDecode(cd[1]);
    const tail = value.split(/[\/\\]/).pop();
    if (tail && fileExt(tail)) return tail;
  }
  return null;
}

/** A file name in link text or a title: "Movie.2024.1080p.mkv (2.1 GB)" gives the name. */
function nameFromText(t) {
  const s = clean(t);
  if (!s || s.length > 300) return null;
  if (s.length <= 180 && !/[\/\\<>|*"]/.test(s) && fileExt(s)) return s;
  let best = null;
  for (const m of s.matchAll(NAME_IN_TEXT)) {
    const cand = m[0].replace(/[.,;:!]+$/, "");
    if (fileExt(cand) && (!best || cand.length > best.length)) best = cand;
  }
  return best;
}

/** Follows redirect links (/out?url=..., google.com/url?q=...) to where they go. */
function unwrap(u) {
  for (let depth = 0; depth < 3; depth++) {
    let inner = null;
    for (const [key, value] of u.searchParams) {
      if (WRAP_KEYS.test(key) && /^https?:\/\//i.test(value)) {
        inner = safeURL(value);
        break;
      }
    }
    if (!inner) return u;
    u = inner;
  }
  return u;
}

function hosterOf(u) {
  const host = u.hostname.toLowerCase().replace(/^www\./, "");
  return HOSTERS.find(h => host === h || host.endsWith("." + h)) || null;
}

/** A file page on a file host (not its home page, premium page and so on). */
function isHosterFile(u) {
  if (!hosterOf(u)) return false;
  const segs = u.pathname.split("/").filter(Boolean);
  if (!segs.length && !u.search && !/^#!?[A-Za-z0-9]/.test(u.hash)) return false;   // the home page
  return !segs.some(seg => HOSTER_PAGE.test(seg));
}

/** A readable name for a link that isn't known to be a file yet. */
function label(c, u) {
  const t = clean(c.text) || clean(c.title);
  if (t && t.length <= 80 && !GENERIC_TEXT.test(t)) return t;
  return lastSegment(u) || u.hostname.replace(/^www\./, "");
}

/**
 * Decides what a collected link is: {kind: "file"} for download files, {kind: "maybe"} for
 * links that look like downloads (to check with the server), or null.
 */
function classify(c) {
  let u = safeURL(c.url);
  if (!u || !/^https?:$/.test(u.protocol)) return null;
  if (NOT_DOWNLOADS.test(u.hostname)) return null;
  u = unwrap(u);
  if (!/^https?:$/.test(u.protocol) || NOT_DOWNLOADS.test(u.hostname)) return null;
  const host = u.hostname.replace(/^www\./, "");
  const path = safeDecode(u.pathname);
  if (IMAGE_EXT.test(path) || ASSET_EXT.test(path)) return null;
  const linkLike = c.source === "link" || c.source === "attr" || c.source === "refresh" || c.source === "click";

  let name = nameFromURL(u);
  if (!name && linkLike) name = nameFromText(c.text) || nameFromText(c.title);
  if (!name && typeof c.download === "string") {
    // <a download>: the site says this is a file, even without a recognisable name.
    const d = c.download.trim().split(/[\/\\]/).pop();
    name = d || lastSegment(u) || host;
  }
  if (!name && c.source === "self" && c.contentType && !/html|xml|json|javascript|css|^image\//i.test(c.contentType)) {
    name = lastSegment(u) || host;   // a PDF, video or other file open in Safari
  }
  if (name) {
    if (IMAGE_EXT.test(name)) return null;
    return { kind: "file", url: u.href, name, ext: fileExt(name) || "", host, size: null };
  }
  // Not obviously a file. Links that say "download", or go to a file host, might be one.
  if (c.source === "script" || c.source === "self" || c.source === "frame") return null;
  const hoster = isHosterFile(u);
  const hinted = (linkLike && c.hint) || DOWNLOAD_PATH.test(u.pathname + u.search);
  if (!hoster && !hinted) return null;
  return { kind: "maybe", url: u.href, name: label(c, u), ext: "", host, hoster, size: null };
}

// ---- Checking links with the server -------------------------------------------------

function readName(disposition) {
  if (!disposition) return null;
  let m = disposition.match(/filename\*\s*=\s*[\w-]*'[^']*'([^;]+)/i);
  if (m) return safeDecode(m[1].trim().replace(/^"|"$/g, ""));
  m = disposition.match(/filename\s*=\s*"([^"]+)"/i) || disposition.match(/filename\s*=\s*([^;]+)/i);
  return m ? m[1].trim() : null;
}

/** What a checked link leads to: "file", "page", "image" or "unknown". */
function judge(r) {
  if (!r || r.error || !r.status) return "unknown";
  if (r.status === 404 || r.status === 410) return "page";   // gone: nothing to download
  if (r.status >= 400) return "unknown";
  const type = (r.type || "").toLowerCase();
  if (/attachment|filename/i.test(r.disposition || "")) return /^image\//.test(type) ? "image" : "file";
  if (!type) return "unknown";
  if (/^image\//.test(type)) return "image";
  if (/html|xml|json|javascript|css|^text\//.test(type)) return "page";
  return "file";
}

function sizeOf(r) {
  const m = (r.range || "").match(/\/(\d+)\s*$/);
  if (m) return Number(m[1]);
  const n = Number(r.length);
  return r.status === 200 && n > 1 ? n : null;
}

function formatSize(n) {
  if (!n) return "";
  const units = ["bytes", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1000 && i < units.length - 1) { n /= 1000; i++; }
  return (i === 0 ? n : n.toFixed(n < 10 ? 1 : 0)) + " " + units[i];
}

// ---- State and list ------------------------------------------------------------------

let files = [];    // download files (all start selected)
let others = [];   // links that might be downloads (start unselected)
const selected = new Set();
let checking = 0;

function addCandidates(list) {
  for (const c of list) {
    const f = classify(c);
    if (!f) continue;
    if (files.some(x => x.url === f.url)) continue;
    if (f.kind === "file") {
      others = others.filter(o => o.url !== f.url);
      files.push(f);
      selected.add(f.url);
    } else if (!others.some(o => o.url === f.url)) {
      f.frameId = c.frameId;
      f.frameOrigin = c.origin;
      others.push(f);
    }
  }
}

function matches(f, q) { return (f.name + " " + f.host).toLowerCase().includes(q); }

function visible(list) {
  const q = $("q").value.trim().toLowerCase();
  return q ? list.filter(f => matches(f, q)) : list;
}

function showMessage(text) { $("message").textContent = text; }

function row(f) {
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
  h.append(document.createTextNode([f.host, formatSize(f.size)].filter(Boolean).join(" · ")));
  t.append(n, h);
  label.append(cb, t);
  li.append(label);
  return li;
}

function render() {
  const shownFiles = visible(files);
  const shownOthers = visible(others);
  const ul = $("list");
  ul.textContent = "";
  shownFiles.forEach(f => ul.append(row(f)));
  const more = $("moreList");
  more.textContent = "";
  shownOthers.forEach(f => more.append(row(f)));
  $("more").hidden = others.length === 0;
  $("moreTitle").textContent = "Other download links (" + others.length + ")";

  const count = files.length;
  $("summary").textContent = (count ? count + (count === 1 ? " file" : " files") : "") +
    (checking ? (count ? " · " : "") + "checking…" : "");
  $("q").hidden = count + others.length < 8;   // the filter box only helps on longer lists
  $("actions").hidden = count + others.length === 0;
  if (count + others.length === 0) {
    showMessage(checking ? "Checking links…" : "No download files found on this page.");
  } else if (!shownFiles.length && !shownOthers.length) {
    showMessage("Nothing matches your filter.");
  } else if (!count) {
    showMessage("No files found for sure, but some links look like downloads.");
  } else {
    showMessage("");
  }
  updateActions();
}

function chosenURLs() {
  return files.concat(others).filter(f => selected.has(f.url)).map(f => f.url);
}

/** jdlite://add?u=...&u=... with as many links as fit. */
function appLink(urls) {
  let link = "jdlite://add?";
  let n = 0;
  for (const u of urls) {
    const part = (n ? "&" : "") + "u=" + encodeURIComponent(u);
    if (n >= MAX_URLS || link.length + part.length > MAX_LINK) break;
    link += part;
    n++;
  }
  return { link, count: n };
}

function updateActions() {
  const urls = chosenURLs();
  const { link, count } = appLink(urls);
  const send = $("send");
  send.href = urls.length ? link : "#";
  send.classList.toggle("disabled", urls.length === 0);
  send.textContent = count > 1 ? "Send " + count + " to JDLite" : "Send to JDLite";
  $("count").textContent = urls.length + " selected" + (urls.length > count ? " (first " + count + " sent)" : "");
  const vis = visible(files);
  $("toggle").textContent = vis.length && vis.every(f => selected.has(f.url)) ? "Select none" : "Select all";
  $("toggle").hidden = files.length === 0;
}

function setPageLink(url) {
  if (!url || !/^https?:/i.test(url)) return;
  const a = $("page");
  a.href = appLink([url]).link;
  a.hidden = false;
}

// ---- Talking to the page and the app ---------------------------------------------------

function withTimeout(promise, ms) {
  return Promise.race([promise, new Promise(resolve => setTimeout(() => resolve(null), ms))]);
}

/** Sends a message to the scanner in one frame of the page. */
async function ask(tabId, message, frameId, ms = 4000) {
  try {
    return await withTimeout(api.tabs.sendMessage(tabId, message, { frameId }), ms);
  } catch (e) {
    if (frameId !== 0) return null;
    try { return await withTimeout(api.tabs.sendMessage(tabId, message), ms); } catch (e2) { return null; }
  }
}

// Opening JDLite from Safari's menu grants access to this page (activeTab), so inject the
// scanner into the page and its frames, then ask each frame for its links.
async function readPage(tabId) {
  let frameIds = [0];
  try {
    const results = await api.scripting.executeScript({ target: { tabId, allFrames: true }, files: ["content.js"] });
    const ids = (results || []).map(r => r && r.frameId).filter(n => Number.isInteger(n));
    if (ids.length) frameIds = Array.from(new Set([0, ...ids]));
  } catch (e) {
    // Some frames can't be read: just the page itself (throws if that can't be read either).
    await api.scripting.executeScript({ target: { tabId }, files: ["content.js"] });
  }
  const replies = await Promise.all(frameIds.map(frameId =>
    ask(tabId, { type: "jdlite-collect-3" }, frameId).then(r => (r && r.links ? Object.assign(r, { frameId }) : null))));
  return replies.filter(Boolean);
}

/** Applies what a server said about a link that might be a download. */
function apply(r) {
  const i = others.findIndex(o => o.url === r.url);
  if (i < 0) return;
  const o = others[i];
  const verdict = judge(r);
  if (verdict === "file") {
    others.splice(i, 1);
    const finalURL = safeURL(r.finalURL);
    const name = readName(r.disposition) || nameFromURL(finalURL) || nameFromURL(safeURL(o.url)) ||
      (finalURL && lastSegment(finalURL)) || o.name;
    const type = (r.type || "").split(";")[0].trim().toLowerCase();
    if (!files.some(f => f.url === o.url)) {
      files.push({ kind: "file", url: o.url, name, ext: fileExt(name) || TYPE_EXT[type] || "", host: o.host, size: sizeOf(r) });
      selected.add(o.url);
    }
  } else if (verdict === "page" || verdict === "image") {
    others.splice(i, 1);
    selected.delete(o.url);
  }
}

/** Asks the JDLite app extension, which can check links on any site. */
async function checkInApp(urls) {
  if (!urls.length || !api.runtime || !api.runtime.sendNativeMessage) return;
  try {
    const reply = await withTimeout(api.runtime.sendNativeMessage("application.id", { type: "check", urls }), 25000);
    for (const r of (reply && reply.results) || []) if (r) apply(r);
  } catch (e) {}
}

/** Finds out which "download" links really lead to files. */
async function checkOthers(tabId) {
  const pending = others.filter(o => !o.hoster).slice(0, MAX_CHECKS);
  if (!pending.length) return;
  checking = pending.length;
  render();
  // Links to the page's own site are checked from the page, with the page's cookies;
  // the rest by the JDLite app extension.
  const byFrame = new Map();
  const viaApp = [];
  for (const o of pending) {
    const u = safeURL(o.url);
    if (u && o.frameOrigin && u.origin === o.frameOrigin && Number.isInteger(o.frameId)) {
      if (!byFrame.has(o.frameId)) byFrame.set(o.frameId, []);
      byFrame.get(o.frameId).push(o.url);
    } else {
      viaApp.push(o.url);
    }
  }
  const jobs = [];
  for (const [frameId, urls] of byFrame) {
    jobs.push(ask(tabId, { type: "jdlite-check-3", urls }, frameId, 25000).then(async reply => {
      const results = (reply && reply.results) || [];
      const retry = urls.filter(u => !results.some(r => r && r.url === u && !r.error));
      results.filter(r => r && !r.error).forEach(apply);
      render();
      await checkInApp(retry);   // e.g. a link that redirects to another site
    }));
  }
  jobs.push(checkInApp(viaApp));
  await Promise.all(jobs);
  checking = 0;
  render();
}

async function init() {
  $("q").addEventListener("input", render);
  $("toggle").addEventListener("click", () => {
    const vis = visible(files);
    const all = vis.length > 0 && vis.every(f => selected.has(f.url));
    vis.forEach(f => (all ? selected.delete(f.url) : selected.add(f.url)));
    render();
  });
  $("copy").addEventListener("click", async () => {
    const urls = chosenURLs();
    if (!urls.length) return;
    try {
      await navigator.clipboard.writeText(urls.join("\n"));
      $("copy").textContent = "Copied";
    } catch (e) {
      showMessage("Couldn't access the clipboard.");
    }
  });

  let tab = null;
  try {
    const tabs = await api.tabs.query({ active: true, currentWindow: true });
    tab = tabs && tabs[0];
  } catch (e) {}
  if (!tab) { showMessage("No page is open."); return; }
  setPageLink(tab.url);

  let replies = [];
  let problem = null;
  try {
    replies = await readPage(tab.id);
  } catch (e) {
    problem = e;
  }
  const candidates = [];
  for (const r of replies) {
    for (const c of r.links || []) {
      c.frameId = r.frameId;
      c.origin = r.origin;
      if (c.source === "self") c.contentType = r.contentType || "";
      candidates.push(c);
    }
  }
  // The page itself can be the file (Safari shows PDFs and videos without a web page around them).
  if (tab.url) candidates.push({ url: tab.url, source: "self", text: "", title: "", contentType: "" });
  addCandidates(candidates);
  render();
  if (problem && !files.length) {
    showMessage("JDLite couldn't read this page (" + ((problem && problem.message) || problem) +
      "). Start pages and Safari's own pages can't be read.");
    return;
  }
  await checkOthers(tab.id);
}

init();
