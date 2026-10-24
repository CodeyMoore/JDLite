// Turns a GitHub release page into direct links for every asset.
registerPlugin({
  id: "github-release",
  name: "GitHub Releases",
  version: "1.1",
  hosts: ["github.com"],
  pattern: "^https://github\\.com/[^/]+/[^/]+/releases/(tag/[^/?#]+|latest)/?(\\?.*)?$",
  async resolve(url, ctx) {
    const m = url.match(/github\.com\/([^\/]+)\/([^\/]+)\/releases\/(?:tag\/([^\/?#]+)|latest)/);
    if (!m) throw new Error("Not a release URL");
    const owner = m[1], repo = m[2], tag = m[3];
    const api = tag
      ? "https://api.github.com/repos/" + owner + "/" + repo + "/releases/tags/" + tag
      : "https://api.github.com/repos/" + owner + "/" + repo + "/releases/latest";
    const r = await ctx.http.get(api, { headers: { Accept: "application/vnd.github+json" } });
    if (r.status !== 200) throw new Error("GitHub API returned " + r.status);
    const rel = JSON.parse(r.body);
    if (!rel.assets || !rel.assets.length) throw new Error("This release has no assets");
    return rel.assets.map(function (a) { return { url: a.browser_download_url, fileName: a.name }; });
  }
});
