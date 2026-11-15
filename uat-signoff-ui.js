/* SB-803 (FU-BTN of SB-791) — Jason's acceptance sign-off on the board, shared
   by jarvis-dashboard.html, jarvis-pwa.html and index.html. Marker: sb803-signoff.

   Loading and wiring: cancel-ui.js (which exactly these three boards load) adds
   this script, and autoWire() below attaches it to each board's edit modal: it
   inserts the #m-uat section above the comments and wraps the board's global
   openModal / openNewModal / closeModal, reading the board's own hdr() or
   getHeaders(), toast(), offlineGuard() and isJason. This keeps the board HTML
   unchanged. When a board's HTML is next edited, it can load this file with its
   own <script> tag and call UatSignoffUI.init() and syncModal() directly, as it
   does for CancelUI; autoWire() then stands down (it skips a board that already
   has #m-uat).

   The edit modal of a ticket in review lists its test cases with their uat
   state, and offers "Sign off" on a live case that has no current sign-off.
   A sign-off is ONE rpc/signoff_test_case_uat call from Jason's own login (the
   server picks the kanban channel). Never a PATCH of test_cases: the uat_*
   columns are guarded by trg_uat_guard and written only by that RPC or by
   Jason's login, and an L4 ticket closes only when one live case carries
   Jason's sign-off from its current review (trg_done_gate_l4).

   counts_for_l4 is shown next to the ticket level. After a click it is the
   value the RPC returned; otherwise it is read from the stored cases with the
   gate's own rule (live case, uat_signed_off_by Jason Paulsen, signed at or
   after review_entered_at).

   Like the approve button (SB-771), the options are only a hint: isJason
   decides what is OFFERED, the database is the gate, and a refusal is shown
   exactly as the database wrote it (SB-776). The cases are re-read after a
   sign-off so the row shows what the server stored. */
(function (root) {
  var RPC = 'signoff_test_case_uat';
  var JASON = 'Jason Paulsen';
  var cfg = null, ticket = null, cases = [], seq = 0, busy = false, last = null, boxId = null;

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function ms(x) { return x ? new Date(x).getTime() : NaN; }
  function fmt(x) {
    if (!x) return '';
    var d = new Date(x);
    return d.toLocaleDateString() + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  }

  /* What one case row shows. Pure, so the unit test can pin it. It mirrors the
     RPC's refusals (retired, archived, already current, ticket not in review)
     so the button appears only where the database would accept it. */
  function caseView(tc, t, isJason) {
    var retired = tc.status === 'retired';
    var archived = !!tc.archived;
    var byJason = tc.uat_signed_off_by === JASON && !!tc.uat_signed_off_at;
    var anchor = t && t.review_entered_at;
    var current = byJason && !!anchor && ms(tc.uat_signed_off_at) >= ms(anchor);
    var state = retired ? 'retired' : archived ? 'archived' : current ? 'current'
      : byJason ? 'earlier' : (tc.uat_signed_off_by || tc.uat_signed_off_at) ? 'other' : 'unsigned';
    var inReview = !!t && t.status === 'review' && !t.archived;
    return {
      state: state,
      counts: current && !retired && !archived,
      canSign: isJason === true && inReview && !retired && !archived && !current,
    };
  }
  function countsForL4(list, t) {
    return (list || []).some(function (tc) { return caseView(tc, t, false).counts; });
  }

  /* The same reading of a PostgREST error body as dbMessage() on the boards. */
  async function dbMessage(r) {
    var raw = '';
    try { raw = await r.text(); } catch (e) { /* ignore */ }
    var m = '';
    try { var b = JSON.parse(raw); m = b.message || b.error_description || b.error || b.hint || ''; } catch (e) { /* not JSON */ }
    return m || ('Sign-off failed (HTTP ' + r.status + ')');
  }

  function injectCss() {
    if (document.getElementById('uat-ui-css')) return;
    var css =
      '.uat-s{margin-top:14px;border-top:1px solid var(--card-b,var(--divider,#2a2f42));padding-top:12px}' +
      '.uat-s h3{display:flex;align-items:center;flex-wrap:wrap;gap:6px;font-size:12px;font-weight:600;text-transform:uppercase;letter-spacing:.5px;color:var(--tx-m,var(--text-muted,#8b949e));margin:0 0 6px}' +
      '.uat-lvl{font-family:"SF Mono",monospace;font-size:11px;padding:1px 6px;border-radius:6px;border:1px solid var(--card-b,var(--card-border,#2a2f42));color:var(--tx,var(--text,#e6edf3));text-transform:none;letter-spacing:0}' +
      '.uat-l4{font-size:11px;padding:1px 7px;border-radius:10px;text-transform:none;letter-spacing:0}' +
      '.uat-l4[data-counts-for-l4="true"]{color:#3fb950;background:rgba(63,185,80,.15)}' +
      '.uat-l4[data-counts-for-l4="false"]{color:#d29922;background:rgba(210,153,34,.15)}' +
      '.uat-sub{font-size:11px;color:var(--tx-m,var(--text-muted,#8b949e));margin-bottom:8px;overflow-wrap:anywhere}' +
      '.uat-case{border:1px solid var(--card-b,var(--card-border,#2a2f42));border-radius:8px;padding:8px 10px;margin-bottom:6px;font-size:12px;color:var(--tx,var(--text,#e6edf3))}' +
      '.uat-case[data-state="retired"],.uat-case[data-state="archived"]{opacity:.55}' +
      '.uat-top{display:flex;align-items:center;gap:8px;flex-wrap:wrap}' +
      '.uat-code{font-family:"SF Mono",monospace;font-size:11px;color:var(--tx-m,var(--text-muted,#8b949e))}' +
      '.uat-title{flex:1;min-width:120px;overflow-wrap:anywhere}' +
      '.uat-state{font-size:11px;padding:1px 7px;border-radius:10px;background:rgba(139,148,158,.15);color:var(--tx-m,var(--text-muted,#8b949e))}' +
      '.uat-state.st-current{color:#3fb950;background:rgba(63,185,80,.15)}' +
      '.uat-state.st-earlier,.uat-state.st-other{color:#d29922;background:rgba(210,153,34,.15)}' +
      '.uat-btn,.uat-go{background:#3fb950;border:1px solid transparent;color:#fff;border-radius:8px;padding:6px 12px;font-size:12px;cursor:pointer}' +
      '.uat-btn:disabled,.uat-go:disabled{opacity:.45;cursor:not-allowed}' +
      '.uat-x{background:transparent;border:1px solid var(--card-b,var(--card-border,#2a2f42));color:var(--tx,var(--text,#e6edf3));border-radius:8px;padding:6px 12px;font-size:12px;cursor:pointer}' +
      '.uat-confirm{display:none;gap:6px;margin-top:8px;flex-wrap:wrap}' +
      '.uat-confirm.open{display:flex}' +
      '.uat-notes{flex:1;min-width:140px;box-sizing:border-box;padding:8px 10px;background:var(--bg,#0d1117);border:1px solid var(--card-b,var(--card-border,#2a2f42));border-radius:8px;color:var(--tx,var(--text,#e6edf3));font-size:16px}' +
      '.uat-meta{font-size:11px;color:var(--tx-m,var(--text-muted,#8b949e));margin-top:4px;overflow-wrap:anywhere}' +
      '.uat-err{display:none;margin-top:6px;font-size:12px;color:var(--red,var(--accent-red,#f85149));overflow-wrap:anywhere}' +
      '.uat-err.open{display:block}';
    var st = document.createElement('style');
    st.id = 'uat-ui-css';
    st.textContent = css;
    document.head.appendChild(st);
  }

  function stateLabel(v, tc) {
    if (v.state === 'retired') return 'Retired';
    if (v.state === 'archived') return 'Archived';
    if (v.state === 'current') return 'Signed off ' + fmt(tc.uat_signed_off_at);
    if (v.state === 'earlier') return 'Signed before this review';
    if (v.state === 'other') return 'Signed by ' + (tc.uat_signed_off_by || '?') + ' (not counted)';
    return 'Not signed off';
  }

  function render() {
    var box = boxId && document.getElementById(boxId);
    if (!box || !ticket) return;
    var isJ = !!(cfg.isJason && cfg.isJason());
    var lvl = ticket.authority_level;
    var counts = (last && last.ticket_id === ticket.id && typeof last.counts_for_l4 === 'boolean')
      ? last.counts_for_l4 : countsForL4(cases, ticket);
    var h = '<h3>Acceptance sign-off' +
      '<span class="uat-lvl" data-level="' + esc(lvl == null ? '' : lvl) + '">' + (lvl == null ? 'L?' : 'L' + esc(lvl)) + '</span>' +
      '<span class="uat-l4" data-counts-for-l4="' + (counts ? 'true' : 'false') + '" title="Does a live case carry Jason\'s sign-off from this review? An L4 ticket needs one to move to done.">counts_for_l4: ' + (counts ? 'yes' : 'no') + '</span></h3>' +
      '<div class="uat-sub">' + (ticket.review_entered_at ? 'In review since ' + esc(fmt(ticket.review_entered_at)) + '. ' : '') +
      (isJ ? 'Sign off a live case to accept this build.' : 'Only Jason\'s own login can sign off.') + '</div>';
    if (!cases.length) h += '<div class="uat-sub">No test cases on this ticket yet.</div>';
    cases.forEach(function (tc) {
      var v = caseView(tc, ticket, isJ);
      var mine = last && last.test_case_id === tc.id;
      h += '<div class="uat-case" data-case-id="' + esc(tc.id) + '" data-state="' + v.state + '">' +
        '<div class="uat-top"><span class="uat-code">' + esc(tc.test_code || '') + '</span>' +
        '<span class="uat-title">' + esc(tc.title || '') + '</span>' +
        '<span class="uat-state st-' + v.state + '">' + esc(stateLabel(v, tc)) + '</span>' +
        (v.canSign ? '<button type="button" class="uat-btn sb803-signoff" data-sb803-signoff="' + esc(tc.id) + '">Sign off</button>' : '') +
        '</div>' +
        ((v.state === 'current' || v.state === 'earlier') && (tc.uat_notes || mine)
          ? '<div class="uat-meta">' + (mine ? 'channel ' + esc(last.channel) + ' · ' : '') + esc(tc.uat_notes || '') + '</div>' : '') +
        (v.canSign ? '<div class="uat-confirm"><input class="uat-notes" maxlength="400" placeholder="Notes (optional)" enterkeyhint="send">' +
          '<button type="button" class="uat-go">Sign off</button><button type="button" class="uat-x">Cancel</button></div>' : '') +
        '<div class="uat-err" role="alert"></div></div>';
    });
    box.innerHTML = h;
    box.querySelectorAll('.uat-case').forEach(function (row) {
      var btn = row.querySelector('.uat-btn');
      if (!btn) return;
      var conf = row.querySelector('.uat-confirm'), notes = row.querySelector('.uat-notes');
      btn.addEventListener('click', function () { conf.classList.add('open'); btn.style.display = 'none'; notes.focus(); });
      row.querySelector('.uat-x').addEventListener('click', function () { conf.classList.remove('open'); btn.style.display = ''; notes.value = ''; });
      var go = function () { signoff(row, row.dataset.caseId, notes.value); };
      row.querySelector('.uat-go').addEventListener('click', go);
      notes.addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); go(); } });
    });
  }

  async function load(it, mySeq) {
    var h = await cfg.headers();
    var id = encodeURIComponent(it.id);
    var [tR, cR] = await Promise.all([
      fetch(cfg.url + '/rest/v1/work_items?id=eq.' + id + '&select=id,ticket_code,status,authority_level,review_entered_at,archived', { headers: h }),
      fetch(cfg.url + '/rest/v1/test_cases?work_item_id=eq.' + id +
        '&select=id,test_code,title,status,archived,uat_signed_off_by,uat_signed_off_at,uat_notes&order=test_code', { headers: h }),
    ]);
    if (mySeq !== seq) return;
    if (!tR.ok) throw new Error(await dbMessage(tR));
    if (!cR.ok) throw new Error(await dbMessage(cR));
    var rows = await tR.json();
    var list = await cR.json();
    if (mySeq !== seq) return;
    ticket = Object.assign({}, it, rows && rows[0] ? rows[0] : {});
    cases = Array.isArray(list) ? list : [];
    render();
  }

  async function signoff(row, caseId, rawNotes) {
    if (busy || !ticket) return;
    if (cfg.offline && cfg.offline()) return;
    var err = row.querySelector('.uat-err'), go = row.querySelector('.uat-go');
    err.classList.remove('open'); err.textContent = '';
    busy = true; if (go) go.disabled = true;
    var t = ticket, mySeq = seq;
    try {
      var h = await cfg.headers();
      var notes = String(rawNotes || '').trim();
      var r = await fetch(cfg.url + '/rest/v1/rpc/' + RPC, {
        method: 'POST', headers: h,
        body: JSON.stringify({ p_test_case_id: caseId, p_quote: null, p_notes: notes || null }),
      });
      if (!r.ok) throw new Error(await dbMessage(r));
      var out = (await r.json()) || {};
      last = { ticket_id: t.id, test_case_id: caseId, channel: out.channel, counts_for_l4: out.counts_for_l4 === true };
      cfg.toast((out.test_code || 'Test case') + ' signed off (' + (out.channel || '?') + ') — counts_for_l4: ' +
        (out.counts_for_l4 === true ? 'yes' : 'no'), 'success', 4000);
      if (mySeq === seq) await load(t, mySeq);
    } catch (e) {
      var m = e && e.message ? e.message : String(e);
      err.textContent = m; err.classList.add('open');
      cfg.toast(m, 'error', 8000);
      if (go) go.disabled = false;
    }
    busy = false;
  }

  /* Edit-modal wiring: shown for a ticket in review only, hidden otherwise. */
  function syncModal(it, id) {
    seq++;
    boxId = id;
    var box = document.getElementById(id);
    if (!box) return;
    if (!it || it.status !== 'review' || it.archived) {
      box.style.display = 'none'; box.innerHTML = ''; ticket = null; cases = []; return;
    }
    if (!last || last.ticket_id !== it.id) last = null;
    ticket = it; cases = [];
    box.style.display = 'block';
    box.innerHTML = '<div class="uat-sub">Loading test cases…</div>';
    var mySeq = seq;
    load(it, mySeq).catch(function (e) {
      if (mySeq !== seq) return;
      box.innerHTML = '<div class="uat-err open" role="alert">' + esc(e && e.message ? e.message : String(e)) + '</div>';
    });
  }

  function init(c) { cfg = c; injectCss(); }

  /* The board globals this module reads. A board that lacks any of them is not
     wired, so a page other than the three boards is left alone. */
  function autoWire() {
    var w = root;
    if (!w.document || document.getElementById('m-uat')) return false;
    if (typeof w.openModal !== 'function' || typeof w.openNewModal !== 'function' || typeof w.closeModal !== 'function') return false;
    var headers = typeof w.hdr === 'function' ? w.hdr : (typeof w.getHeaders === 'function' ? w.getHeaders : null);
    var anchor = document.getElementById('cmt-s') || document.getElementById('comments-section');
    if (!headers || typeof w.toast !== 'function' || !anchor || !w.SB_CONFIG) return false;
    var box = document.createElement('div');
    box.className = 'uat-s';
    box.id = 'm-uat';
    box.setAttribute('data-sb803', 'signoff');
    box.style.display = 'none';
    anchor.parentNode.insertBefore(box, anchor);
    init({
      url: w.SB_CONFIG.url,
      headers: headers,
      toast: function (m, t, d) { w.toast(m, t || 'success', d); },
      offline: typeof w.offlineGuard === 'function' ? w.offlineGuard : function () {
        if (navigator.onLine === false) { w.toast('Offline — changes are locked', 'error'); return true; }
        return false;
      },
      isJason: function () { return w.isJason === true; },
    });
    // The item the board's modal holds: editItem (pwa, index) or editingItem (dashboard).
    var held = function () { return w.editItem || w.editingItem || null; };
    var openModal = w.openModal, openNewModal = w.openNewModal, closeModal = w.closeModal;
    w.openModal = function (itemId) {
      var r = openModal.apply(this, arguments);   // sets the held item before its first await
      var it = held();
      syncModal(it && it.id === itemId ? it : null, 'm-uat');
      return r;
    };
    w.openNewModal = function () {
      var r = openNewModal.apply(this, arguments);
      syncModal(null, 'm-uat');
      return r;
    };
    w.closeModal = function () {
      var r = closeModal.apply(this, arguments);
      syncModal(null, 'm-uat');
      return r;
    };
    return true;
  }

  var api = {
    RPC: RPC,
    MARKER: 'sb803-signoff',
    init: init,
    syncModal: syncModal,
    autoWire: autoWire,
    caseView: caseView,
    countsForL4: countsForL4,
  };
  root.UatSignoffUI = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  // The boards define their globals in inline scripts at the end of <body>, so
  // wire once parsing is done (this file may arrive before or after that).
  if (typeof document !== 'undefined') {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', autoWire);
    else autoWire();
  }
})(typeof window !== 'undefined' ? window : globalThis);
