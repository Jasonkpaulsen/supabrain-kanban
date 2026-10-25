# Article Studio (PWA)

Mobile-first PWA for the **LinkedIn Content Engine** — review, editorial feedback, approve, schedule, and manage articles + header images. Supabase-backed; mobile companion to the desktop console. Served from `/article-studio/` (self-contained, relative paths).

Install: open `<host>/article-studio/` on your phone over HTTPS → Add to Home Screen. Sign in with your Supabase email/password.

Files: `index.html` (whole app), `config.js` (URL and publishable key), `manifest.webmanifest`, `sw.js` (never caches Supabase data), `icon.svg`. Access is enforced by RLS.

**This folder is the only home of Article Studio (SB-632, Jason 2026-10-25).** Change the app only here; the lce-article-studio repository is retired. Tests: `tests/e2e/article-studio-removal.spec.js` (stubbed backend, part of the repo's Playwright suite).
