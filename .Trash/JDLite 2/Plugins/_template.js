/*
  JDLite plugin template. Copy this file, then change `id`, `hosts` and `resolve`.

  registerPlugin({
    id:       unique string
    name:     shown in the Plugins screen
    version:  optional
    hosts:    ["example.com"]   matches the host and its subdomains
    pattern:  optional regex (string) tested against the full URL
    accounts: true if resolve() uses ctx.account (the matching account is passed in)
    async resolve(url, ctx) -> link | [links]
  })

  link = { url, fileName?, headers? }    headers are sent with the final download

  ctx.http.get(url, {headers})
  ctx.http.post(url, bodyObjectOrString, {headers})
  ctx.http.postJSON(url, object, {headers})
  ctx.http.request({method, url, headers, body, follow})
      -> Promise<{ status, headers (lowercase keys), body (string), url (final) }>
  ctx.http.cookieHeader(url)  Cookie header built from cookies set during this resolve
  ctx.account                 { label, username, password, cookies } or null
  ctx.absURL(rel, base)       resolve a relative URL (there is no global URL class)
  ctx.decodeHTML(str)         &amp; &quot; ... -> characters
  ctx.log(...), ctx.sleep(ms)
*/
registerPlugin({
  id: "example-template",
  name: "Example template",
  version: "1.0",
  hosts: ["example.invalid"],
  async resolve(url, ctx) {
    const r = await ctx.http.get(url);
    if (r.status !== 200) throw new Error("HTTP " + r.status);
    const m = r.body.match(/href="([^"]+\.(?:zip|pdf|mp4))"/i);
    if (!m) throw new Error("No download link found on the page");
    return { url: ctx.absURL(ctx.decodeHTML(m[1]), url) };
  }
});
