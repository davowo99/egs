/* EGS service worker: lets the app open with no internet (downloaded songs live in the app's own storage). */
const V = "egs-v1";
const SHELL = ["./", "index.html", "manifest.json", "icon-192.png", "icon-512.png",
  "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(V)
    .then(c => Promise.all(SHELL.map(u => c.add(u).catch(() => {}))))
    .then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys()
    .then(ks => Promise.all(ks.filter(k => k !== V).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

async function clean(res) { // a redirected response can't be handed to a page load
  if (!res.redirected) return res;
  return new Response(await res.clone().blob(), { status: res.status, headers: res.headers });
}
async function pageRequest(r) { // network first (so updates arrive), cached copy when offline or slow
  const c = await caches.open(V);
  try {
    const ctrl = new AbortController(), t = setTimeout(() => ctrl.abort(), 4000);
    const res = await clean(await fetch(r.url, { signal: ctrl.signal }));
    clearTimeout(t);
    if (res.ok) c.put("index.html", res.clone());
    return res;
  } catch (err) {
    return (await c.match("index.html")) || (await c.match("./")) || Response.error();
  }
}
async function assetRequest(r) { // cached copy now, refreshed in the background
  const c = await caches.open(V), hit = await c.match(r);
  const net = fetch(r).then(res => { if (res && (res.ok || res.type === "opaque")) c.put(r, res.clone()); return res; }).catch(() => null);
  return hit || (await net) || Response.error();
}
self.addEventListener("fetch", e => {
  const r = e.request;
  if (r.method !== "GET" || r.headers.has("range")) return;
  const u = new URL(r.url);
  if (r.mode === "navigate") e.respondWith(pageRequest(r));
  else if (u.origin === location.origin || u.hostname === "cdn.jsdelivr.net") e.respondWith(assetRequest(r));
});
