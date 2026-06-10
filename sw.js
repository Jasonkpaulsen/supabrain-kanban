// JARVIS PWA — Service Worker
const CACHE_NAME = 'kanban-pwa-v3';
const SUPABASE_HOST = 'hzqqvbvhnzmgqivfigej.supabase.co';

// App shell files to precache
const APP_SHELL = [
  './index.html',
  './manifest.json',
  './kanban-icon.svg',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2'
];

// ------------------------------------------------------------------
// Install — cache the app shell
// ------------------------------------------------------------------
self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL))
  );
  self.skipWaiting();
});

// ------------------------------------------------------------------
// Activate — clean old caches
// ------------------------------------------------------------------
self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

// ------------------------------------------------------------------
// Fetch — network-first for API & HTML, cache-first for assets
// ------------------------------------------------------------------
self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);

  // Supabase API calls — network first, fall back to cache
  if (url.hostname === SUPABASE_HOST) {
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
// Background Sync — replay queued mutations when back online
// ------------------------------------------------------------------
self.addEventListener('sync', (e) => {
  if (e.tag === 'sync-mutations') {
    e.waitUntil(replayQueue());
  }
});

async function replayQueue() {
  const db = await openSyncDB();
  const tx = db.transaction('mutations', 'readonly');
  const store = tx.objectStore('mutations');
  const all = await idbGetAll(store);

  for (const entry of all) {
    try {
      const res = await fetch(entry.url, {
        method: entry.method,
        headers: entry.headers,
        body: entry.body
      });
      if (res.ok) {
        const delTx = db.transaction('mutations', 'readwrite');
        delTx.objectStore('mutations').delete(entry.id);
        await idbComplete(delTx);
      }
    } catch (_) {
      break;
    }
  }
}

// Simple IndexedDB helpers
function openSyncDB() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open('kanban-sync', 1);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains('mutations')) {
        db.createObjectStore('mutations', { keyPath: 'id', autoIncrement: true });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

function idbGetAll(store) {
  return new Promise((resolve, reject) => {
    const req = store.getAll();
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

function idbComplete(tx) {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

// ------------------------------------------------------------------
// Message handler — receive queued mutations from the client
// ------------------------------------------------------------------
self.addEventListener('message', (e) => {
  if (e.data && e.data.type === 'QUEUE_MUTATION') {
    openSyncDB().then((db) => {
      const tx = db.transaction('mutations', 'readwrite');
      tx.objectStore('mutations').add(e.data.payload);
      return idbComplete(tx);
    });
  }
});
