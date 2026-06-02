// CIP Build Board — Service Worker
const CACHE_NAME = 'cip-board-v1';
const SUPABASE_HOST = 'hzqqvbvhnzmgqivfigej.supabase.co';

// App shell precached for offline launch
const APP_SHELL = [
  './kanban-pwa-cip.html',
  './manifest-cip.json',
  './kanban-icon.svg',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2'
];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL)));
  self.skipWaiting();
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);

  // Supabase API / auth: always network-first (never serve stale board data); fall back to cache only if offline.
  if (url.hostname === SUPABASE_HOST) {
    e.respondWith(
      fetch(e.request).catch(() => caches.match(e.request))
    );
    return;
  }

  // App shell & static assets: cache-first, then network, and cache successful GETs.
  e.respondWith(
    caches.match(e.request).then((cached) => {
      if (cached) return cached;
      return fetch(e.request).then((resp) => {
        if (e.request.method === 'GET' && resp && resp.status === 200 && resp.type === 'basic') {
          const copy = resp.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(e.request, copy));
        }
        return resp;
      }).catch(() => cached);
    })
  );
});
