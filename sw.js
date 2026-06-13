// JARVIS PWA — Service Worker
// SB-184: Fixed references (was kanban-pwa.html)
// SB-185: Safe update flow (skipWaiting only on user acceptance)
// SB-186: Background-sync queue removed, cache purge on logout
// SB-199/200: Domain-aware narrative swap in dashboards
const CACHE_NAME = 'jarvis-pwa-v6';
const SUPABASE_HOST = 'hzqqvbvhnzmgqivfigej.supabase.co';

// App shell files to precache
const APP_SHELL = [
  './jarvis-pwa.html',
  './manifest.json',
  './kanban-icon.svg',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2'
];

// ------------------------------------------------------------------
// Install — cache the app shell, but do NOT auto-skipWaiting
// The client will send SKIP_WAITING when the user accepts the update
// ------------------------------------------------------------------
self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL))
  );
  // Do NOT call self.skipWaiting() here — wait for user acceptance
});

// ------------------------------------------------------------------
// Activate — clean old caches, then claim clients
// ------------------------------------------------------------------
self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

// ------------------------------------------------------------------
// Fetch — network-first for API, cache-first for shell
// ------------------------------------------------------------------
self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);

  // Supabase API calls — network first, fall back to cache
  if (url.hostname === SUPABASE_HOST) {
    // Only cache GET requests (reads)
    if (e.request.method === 'GET') {
      e.respondWith(
        fetch(e.request)
          .then((res) => {
            const clone = res.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(e.request, clone));
            return res;
          })
          .catch(() => caches.match(e.request))
      );
    }
    // Non-GET API calls: just fetch, don't cache
    return;
  }

  // HTML pages — network first so code updates land immediately
  if (url.pathname.endsWith('.html') || url.pathname.endsWith('/')) {
    e.respondWith(
      fetch(e.request)
        .then((res) => {
          const clone = res.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(e.request, clone));
          return res;
        })
        .catch(() => caches.match(e.request))
    );
    return;
  }

  // Other app shell & CDN assets — cache first, fall back to network
  e.respondWith(
    caches.match(e.request).then((cached) => {
      if (cached) return cached;
      return fetch(e.request).then((res) => {
        if (res.ok) {
          const clone = res.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(e.request, clone));
        }
        return res;
      });
    })
  );
});

// ------------------------------------------------------------------
// Message handler — SKIP_WAITING + PURGE_CACHE
// No background-sync queue — removed per SB-186 (governance guardrail)
// ------------------------------------------------------------------
self.addEventListener('message', (e) => {
  // User accepted the update toast — activate the new SW now
  if (e.data && e.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }

  // Logout — purge all cached API responses to prevent stale auth data
  if (e.data && e.data.type === 'PURGE_CACHE') {
    caches.open(CACHE_NAME).then((cache) => {
      cache.keys().then((requests) => {
        requests.forEach((req) => {
          const url = new URL(req.url);
          // Delete cached Supabase API responses (authenticated data)
          if (url.hostname === SUPABASE_HOST) {
            cache.delete(req);
          }
        });
      });
    });
  }
});
