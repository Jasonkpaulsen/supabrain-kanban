# Article Studio (PWA)

Mobile-first PWA for the **LinkedIn Content Engine** — review, editorial feedback, approve, schedule, and manage articles + header images. Supabase-backed; mobile companion to the desktop console. Served from `/article-studio/` (self-contained, relative paths).

Install: open `<host>/article-studio/` on your phone over HTTPS → Add to Home Screen. Sign in with your Supabase email/password.

Files: `index.html` (whole app), `manifest.webmanifest`, `sw.js` (never caches Supabase data), `icon.svg`. The embedded key is the publishable anon key; access is enforced by RLS.
