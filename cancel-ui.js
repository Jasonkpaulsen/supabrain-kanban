/* SB-565 — cancelled-state UI shared by jarvis-dashboard.html, jarvis-pwa.html
   and index.html (spec: docs/ui/SB-564-cancelled-state.md, ADR-FLOW-004).

   One implementation of the cancel dialog, the reason line and reopen, so the
   three boards cannot drift. Each board calls CancelUI.init() with adapters for
   the things it names differently (headers, toast, reload, its item list, the
   signed-in actor). Cancelling always goes through rpc/cancel_work_item, which
   carries the reason; the database refuses a bare status change to cancelled. */
(function () {
  var REASONS = [
    ['duplicate', 'Duplicate'],
    ['superseded', 'Superseded'],
    ['no_longer_relevant', 'No longer relevant'],
    ['wont_do', "Won't do"],
    ['rejected_by_jason', 'Rejected by Jason']
  ];
  var NEEDS_TICKET = { duplicate: true, superseded: true };
  var cfg = null, current = null, reason = null;

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function injectCss() {
    var css =
      '.card.cancelled{opacity:.7}' +
      '.card.cancelled .card-title{text-decoration:line-through;color:var(--tx-m,var(--text-muted,#8b949e))}' +
      '.card-cancel{font-size:11px;line-height:1.35;color:var(--tx-m,var(--text-muted,#8b949e));margin-top:4px;overflow-wrap:anywhere}' +
      '.cx-btn{background:transparent;color:var(--red,var(--accent-red,#f85149));border:1px solid rgba(248,81,73,.35);border-radius:8px;padding:8px 12px;font-size:13px;cursor:pointer}' +
      '.cx-btn:hover{background:rgba(248,81,73,.08)}' +
      '.cx-banner{display:none;margin:0 0 12px;padding:8px 10px;border-radius:8px;border:1px solid #6e7681;background:rgba(110,118,129,.12);font-size:12px;line-height:1.4;color:var(--tx,var(--text,#e6edf3));overflow-wrap:anywhere}' +
      '.cx-banner b{color:#6e7681;text-transform:uppercase;letter-spacing:.4px;margin-right:4px}' +
      '#cancel-dlg-bg{position:fixed;inset:0;background:rgba(0,0,0,.55);display:none;align-items:center;justify-content:center;z-index:10000;padding:16px}' +
      '#cancel-dlg-bg.open{display:flex}' +
      '#cancel-dlg{background:var(--sf,var(--surface,#161b22));border:1px solid var(--card-b,var(--card-border,#2a2f42));border-radius:14px;width:100%;max-width:440px;padding:18px;color:var(--tx,var(--text,#e6edf3));box-sizing:border-box}' +
      '#cancel-dlg h3{margin:0 0 2px;font-size:16px}' +
      '#cancel-dlg .cx-sub{font-size:12px;color:var(--tx-m,var(--text-muted,#8b949e));margin-bottom:12px;overflow-wrap:anywhere}' +
      '#cancel-dlg .cx-reasons{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:12px}' +
      '#cancel-dlg .cx-reason{border:1px solid var(--card-b,var(--card-border,#2a2f42));background:transparent;color:var(--tx,var(--text,#e6edf3));border-radius:16px;padding:7px 11px;font-size:12px;cursor:pointer}' +
      '#cancel-dlg .cx-reason[aria-pressed="true"]{border-color:#6e7681;background:rgba(110,118,129,.25)}' +
      '#cancel-dlg label{display:block;font-size:12px;color:var(--tx-m,var(--text-muted,#8b949e));margin-bottom:4px}' +
      '#cancel-dlg input{width:100%;box-sizing:border-box;padding:10px 12px;background:var(--bg,#0d1117);border:1px solid var(--card-b,var(--card-border,#2a2f42));border-radius:8px;color:var(--tx,var(--text,#e6edf3));font-size:16px}' +
      '#cancel-dlg .cx-err{display:none;margin-top:10px;font-size:12px;color:var(--red,var(--accent-red,#f85149));overflow-wrap:anywhere}' +
      '#cancel-dlg .cx-actions{display:flex;justify-content:flex-end;gap:8px;margin-top:14px;flex-wrap:wrap}' +
      '#cancel-dlg .cx-keep{background:transparent;border:1px solid var(--card-b,var(--card-border,#2a2f42));color:var(--tx,var(--text,#e6edf3));border-radius:8px;padding:9px 14px;font-size:13px;cursor:pointer}' +
      '#cancel-dlg .cx-go{background:var(--red,var(--accent-red,#f85149));border:1px solid transparent;color:#fff;border-radius:8px;padding:9px 14px;font-size:13px;cursor:pointer}' +
      '#cancel-dlg .cx-go:disabled{opacity:.45;cursor:not-allowed}' +
      '@media (max-width:600px){#cancel-dlg-bg{align-items:flex-end;padding:0}#cancel-dlg{max-width:none;border-radius:14px 14px 0 0}}';
    var st = document.createElement('style');
    st.id = 'cancel-ui-css';
    st.textContent = css;
    document.head.appendChild(st);
  }

  function injectDialog() {
    var bg = document.createElement('div');
    bg.id = 'cancel-dlg-bg';
    bg.innerHTML =
      '<div id="cancel-dlg" role="dialog" aria-modal="true" aria-labelledby="cx-h">' +
      '<h3 id="cx-h"></h3><div class="cx-sub" id="cx-sub"></div>' +
      '<div class="cx-reasons" id="cx-reasons">' +
      REASONS.map(function (r) {
        return '<button type="button" class="cx-reason" aria-pressed="false" data-r="' + r[0] + '">' + r[1] + '</button>';
      }).join('') +
      '</div>' +
      '<div id="cx-field" style="display:none"><label for="cx-input" id="cx-label"></label><input id="cx-input" autocomplete="off"></div>' +
      '<div class="cx-err" id="cx-err" role="alert"></div>' +
      '<div class="cx-actions"><button type="button" class="cx-keep" id="cx-keep">Keep ticket</button>' +
      '<button type="button" class="cx-go" id="cx-go" disabled>Cancel ticket</button></div></div>';
    document.body.appendChild(bg);
    bg.addEventListener('click', function (e) { if (e.target === bg) close(); });
    document.getElementById('cx-keep').addEventListener('click', close);
    document.getElementById('cx-input').addEventListener('input', validate);
    document.getElementById('cx-go').addEventListener('click', submit);
    bg.querySelectorAll('.cx-reason').forEach(function (b) {
      b.addEventListener('click', function () { pick(b.dataset.r); });
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && bg.classList.contains('open')) { e.stopImmediatePropagation(); close(); }
    }, true);
  }

  function pick(r) {
    reason = r;
    document.querySelectorAll('#cx-reasons .cx-reason').forEach(function (b) {
      b.setAttribute('aria-pressed', b.dataset.r === r ? 'true' : 'false');
    });
    var inp = document.getElementById('cx-input');
    document.getElementById('cx-field').style.display = 'block';
    document.getElementById('cx-label').textContent = NEEDS_TICKET[r] ? 'Replacing ticket (e.g. SB-382)' : 'Why? (one line)';
    inp.placeholder = NEEDS_TICKET[r] ? 'SB-382' : 'One line';
    inp.value = '';
    showError('');
    validate();
    inp.focus();
  }

  function validate() {
    var v = document.getElementById('cx-input').value.trim();
    var ok = !!reason && (NEEDS_TICKET[reason] ? /^[A-Za-z0-9]+-[0-9]+$/.test(v) : v.length >= 3);
    document.getElementById('cx-go').disabled = !ok;
    return ok;
  }

  function showError(msg) {
    var e = document.getElementById('cx-err');
    e.textContent = msg;
    e.style.display = msg ? 'block' : 'none';
  }

  // PostgREST error bodies are JSON with a message; keep only what a person can act on.
  async function errorText(res) {
    var raw = '';
    try { raw = await res.text(); } catch (e) { /* ignore */ }
    try { var j = JSON.parse(raw); if (j && j.message) return j.message; } catch (e) { /* not JSON */ }
    return raw || ('HTTP ' + res.status);
  }

  async function rpc(name, body) {
    var h = await cfg.headers();
    return fetch(cfg.url + '/rest/v1/rpc/' + name, { method: 'POST', headers: h, body: JSON.stringify(body) });
  }

  function openCancel(item) {
    if (!item) return;
    if (cfg.offline && cfg.offline()) return;
    current = item;
    reason = null;
    document.getElementById('cx-h').textContent = 'Cancel ' + (item.ticket_code || 'this ticket') + '?';
    document.getElementById('cx-sub').textContent = item.title || '';
    document.querySelectorAll('#cx-reasons .cx-reason').forEach(function (b) { b.setAttribute('aria-pressed', 'false'); });
    document.getElementById('cx-field').style.display = 'none';
    document.getElementById('cx-input').value = '';
    document.getElementById('cx-go').disabled = true;
    showError('');
    document.getElementById('cancel-dlg-bg').classList.add('open');
    var first = document.querySelector('#cx-reasons .cx-reason');
    if (first) first.focus();
  }

  function close() {
    document.getElementById('cancel-dlg-bg').classList.remove('open');
    current = null;
    reason = null;
  }

  async function submit() {
    if (!current || !validate()) return;
    var v = document.getElementById('cx-input').value.trim();
    var go = document.getElementById('cx-go');
    go.disabled = true;
    try {
      var actor = await cfg.actor();
      var res = await rpc('cancel_work_item', {
        p_item_id: current.id,
        p_reason: reason,
        p_note: NEEDS_TICKET[reason] ? null : v,
        p_replaced_by: NEEDS_TICKET[reason] ? v.toUpperCase() : null,
        p_actor: actor
      });
      if (!res.ok) { showError(await errorText(res)); go.disabled = false; return; }
      var code = current.ticket_code;
      close();
      if (cfg.afterChange) cfg.afterChange();
      cfg.toast('Cancelled' + (code ? ' ' + code : ''));
      await cfg.reload();
    } catch (e) {
      showError(e.message || String(e));
      go.disabled = false;
    }
  }

  async function reopen(item) {
    if (!item) return;
    if (cfg.offline && cfg.offline()) return;
    try {
      var actor = await cfg.actor();
      var res = await rpc('reopen_work_item', { p_item_id: item.id, p_status: 'backlog', p_actor: actor });
      var waiting = false;
      if (!res.ok) {
        var msg = await errorText(res);
        // L3+ and rejected_by_jason tickets may only come back to Jason's queue.
        if (msg.indexOf('CANCEL-005') === -1) throw new Error(msg);
        res = await rpc('reopen_work_item', { p_item_id: item.id, p_status: 'awaiting_jason', p_actor: actor });
        if (!res.ok) throw new Error(await errorText(res));
        waiting = true;
      }
      if (cfg.afterChange) cfg.afterChange();
      cfg.toast(waiting ? "Reopened — waiting for Jason's decision" : 'Reopened to Backlog');
      await cfg.reload();
    } catch (e) {
      cfg.toast('Reopen failed: ' + (e.message || e), 'error');
    }
  }

  // "Duplicate of SB-382 · Jason" etc. Returns escaped HTML.
  function reasonLine(it) {
    if (!it || it.status !== 'cancelled') return '';
    var repl = 'another ticket';
    if (it.cancel_replaced_by) {
      var r = (cfg.items() || []).find(function (x) { return x.id === it.cancel_replaced_by; });
      if (r && r.ticket_code) repl = r.ticket_code;
    }
    var note = it.cancel_note || '';
    var shortNote = note.length > 80 ? note.slice(0, 79) + '…' : note;
    var lead = {
      duplicate: 'Duplicate of ' + repl,
      superseded: 'Superseded by ' + repl,
      no_longer_relevant: 'No longer relevant',
      wont_do: "Won't do",
      rejected_by_jason: 'Rejected by Jason'
    }[it.cancel_reason] || 'Cancelled';
    var txt = lead + (NEEDS_TICKET[it.cancel_reason] || !shortNote ? '' : ' — ' + shortNote) +
      (it.cancelled_by ? ' · ' + it.cancelled_by : '');
    return '<div class="card-cancel" title="' + esc(note) + '">' + esc(txt) + '</div>';
  }

  function bannerText(it) {
    var d = it.cancelled_at ? new Date(it.cancelled_at).toLocaleDateString() : '';
    var line = reasonLine(it).replace(/<[^>]*>/g, '');
    var tmp = document.createElement('textarea');
    tmp.innerHTML = line;
    return '<b>Cancelled</b>' + esc(tmp.value) + (d ? ' · ' + esc(d) : '');
  }

  // Edit-modal wiring: banner above the fields, one action button that is either
  // "Cancel ticket…" or "Reopen", and the status select locked while cancelled.
  function syncModal(it, ids) {
    var banner = document.getElementById(ids.banner);
    var btn = document.getElementById(ids.button);
    var sel = document.getElementById(ids.status);
    if (!it) {
      banner.style.display = 'none';
      btn.style.display = 'none';
      sel.disabled = false;
      return;
    }
    btn.style.display = 'inline-flex';
    if (it.status === 'cancelled') {
      banner.innerHTML = bannerText(it);
      banner.style.display = 'block';
      btn.textContent = 'Reopen';
      btn.dataset.mode = 'reopen';
      sel.disabled = true;
    } else {
      banner.style.display = 'none';
      btn.textContent = 'Cancel ticket…';
      btn.dataset.mode = 'cancel';
      sel.disabled = false;
    }
  }

  window.CancelUI = {
    STATUS: 'cancelled',
    COLOR: '#6e7681',
    NAME: 'Cancelled',
    init: function (c) { cfg = c; injectCss(); injectDialog(); },
    openCancel: openCancel,
    reopen: reopen,
    reasonLine: reasonLine,
    syncModal: syncModal,
    isOpen: function () { return document.getElementById('cancel-dlg-bg').classList.contains('open'); }
  };
})();
