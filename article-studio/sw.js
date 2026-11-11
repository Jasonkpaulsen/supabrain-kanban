// Article Studio service worker — app-shell cache, network-first for data.
// LCE-021 (#14): v3 for mobile image curation.
// SB-182: config.js enters the shell. SB-631: the removal fix in index.html.
// SB-633/SB-635: library-safe removals and purge logging.
// SB-632 port of ae45367 onto main: v6, above both main's v3 and the branch's v5.
const CACHE = 'article-studio-v6';
const SHELL = ['./', './index.html', './config.js', './manifest.webmanifest', './icon.svg'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (url.hostname.endsWith('supabase.co')) return;
  if (e.request.mode === 'navigate') {
    e.respondWith(fetch(e.request).catch(() => caches.match('./index.html')));
    return;
  }
  e.respondWith(caches.match(e.request).then((r) => r || fetch(e.request)));
});
