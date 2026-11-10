// Keeps the install page available offline. The IPA and manifest are never cached:
// iOS's installer downloads them itself, outside the browser.
const CACHE = "watch-installer-__BUILD_ID__";
const SHELL = ["./", "index.html", "app.webmanifest", "icon-180.png", "icon-512.png", "info.json"];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== "GET" || url.origin !== location.origin) return;
  if (/\.(ipa|plist)$/.test(url.pathname)) return;

  // Build details: network first so a new build shows up, cached copy when offline.
  if (url.pathname.endsWith("/info.json")) {
    event.respondWith(
      fetch(event.request)
        .then((response) => {
          const copy = response.clone();
          caches.open(CACHE).then((cache) => cache.put("info.json", copy));
          return response;
        })
        .catch(() => caches.match("info.json"))
    );
    return;
  }

  // Everything else: cached copy first, then the network.
  event.respondWith(
    caches.match(event.request, { ignoreSearch: true }).then((cached) => cached || fetch(event.request))
  );
});
