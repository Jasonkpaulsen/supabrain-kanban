# SB-564: Cancelled state, UI spec (web and mobile)

- **Author:** SupaBrain Front End Designer, 2026-10-10.
- **Builds on:** ADR-FLOW-004 and the SB-562 reason vocabulary. Built by SB-565 and verified by SB-566.
- **Surfaces:**
  - `jarvis-dashboard.html`: desktop, every column side by side, drag and drop.
  - `jarvis-pwa.html`: mobile-first, one column at a time behind tabs, long-press move sheet.
  - `index.html`: the kanban view, a near-copy of the PWA that receives the same treatment.

## 1. Principles

1. **A cancelled ticket never reads as done.** No green, no check mark, and no count toward done or completion %.
2. **Cancelled is visible, not hidden.** It gets its own place on every surface. After 14 days the archival sweep takes it off the default board, the same as done work.
3. **Cancelling takes a reason.** It is never a drag into a column or a pick from the status list. Both of those routes open the cancel dialog.

## 2. Tokens

| Token | Value | Use |
|-------|-------|-----|
| status colour `cancelled` | `#6e7681` (neutral grey; distinct from backlog `#8b949e` and done `#3fb950`) | column header, tab underline, status badge |
| card treatment | `opacity: .7`; title `text-decoration: line-through`, muted text colour | card |
| danger action | existing red (`--red` / `--accent-red`) on a transparent fill | "Cancel ticket…" |

The boards currently ship one (dark) theme. Every new rule uses the existing CSS variables plus the one status colour, so a later light theme picks them up with no change.

## 3. Card

**Meta row:** the status badge reads **Cancelled** in the grey token, in place of the normal status badge.

**Below the title:** one reason line, class `.card-cancel`, that wraps at 300 px or 360 px:

| Reason | Line |
|--------|------|
| duplicate | "Duplicate of SB-382" |
| superseded | "Superseded by SB-257" |
| no_longer_relevant | "No longer relevant — *note*" |
| wont_do | "Won't do — *note*" |
| rejected_by_jason | "Rejected by Jason — *note*" |

The line always ends with " · *who*". The replacing ticket's code comes from the loaded board; if that ticket is not loaded, the line says "another ticket". The note is cut at 80 characters, with the full text in the `title` tooltip.

**Never shown on a cancelled card:**
- the overdue colour on its due date;
- subtask-progress green;
- the NEW badge.

## 4. Where cancelled tickets live

- **Dashboard:** a **Cancelled** column after Done, with a header count. Its "+ Add card" button is hidden, because you cannot create a ticket as cancelled. The status filter chips gain "Cancelled".
- **PWA / kanban:** a **Cancelled** tab after Done in the column tabs. It scrolls horizontally with the others; nothing is added at 360 px. The status filter chips gain "Cancelled".
- **Empty state:** "No cancelled items" (the existing per-column empty text).

## 5. Counts

Wherever a board shows totals, cancelled tickets leave the denominator:
- the stats strip: total, done %, and the delivery bar segments;
- the per-agent open/done bars.

So cancelling an open ticket raises the done %, and cancelling never adds to done. This mirrors `jarvis_ops_metrics` after SB-563.

## 6. Cancelling

**Entry points:**

| Surface | Entry point |
|---------|-------------|
| Edit modal, all boards | a **Cancel ticket…** button, danger-outline, beside Delete. Shown for any ticket not already cancelled. |
| PWA / kanban move sheet (long press) | a **Cancel ticket…** row under the status list, in red. |
| Dashboard drag | dropping a card on the Cancelled column opens the dialog; the card moves only if the dialog succeeds. |

The status drop-downs never offer Cancelled.

**Dialog** (`#cancel-dlg`: a centred modal on desktop, a bottom sheet under 600 px), in this order:
1. **Heading:** "Cancel *SB-123*?", with the title on a second line.
2. **Reason picker:** five chips, single select, in this order: Duplicate · Superseded · No longer relevant · Won't do · Rejected by Jason. None is selected at first.
3. **Conditional field:**
   - Duplicate / Superseded: a text input, "Replacing ticket (e.g. SB-382)", stored upper-case.
   - Any other reason: a one-line input, "Why? (one line)", 3+ characters.
4. **Buttons:** **Keep ticket** (secondary, closes the dialog) and **Cancel ticket** (danger). Cancel ticket stays disabled until a reason and its field are valid.
5. **On confirm:**
   - **Call:** the dialog calls `rpc/cancel_work_item` with `p_actor` = the signed-in person's name, falling back to their email.
   - **On success:** it closes, the board reloads, and a toast reads "Cancelled".
   - **On a server refusal (CANCEL-00x, GOV-001):** the dialog stays open and the message appears inside it. It does not appear as a toast, so the person can fix the reason.

**Width:** at 360 px the chips wrap onto two rows and the inputs are full width. There is no horizontal scroll.

## 7. Viewing and reopening

The edit modal of a cancelled ticket shows a grey banner above the fields: "**Cancelled** · *reason line* · *date*".
- The Status drop-down is disabled.
- Save still edits title, description, priority and the other ordinary fields.
- **Reopen** (secondary) replaces "Cancel ticket…". It calls `rpc/reopen_work_item` with `backlog`. If the server answers CANCEL-005 (L3+ or rejected by Jason), it retries with `awaiting_jason` and the toast says "Reopened — waiting for Jason's decision".

On the PWA move sheet a cancelled ticket offers only **Reopen**. A cancelled ticket cannot be dragged on the dashboard; a drop is refused with a toast pointing to Reopen.

## 8. Accessibility

- The reason chips are buttons with `aria-pressed`.
- The dialog has `role="dialog"`, `aria-modal="true"`, and focus moves to the first chip when it opens.
- The struck-through title keeps its text, and the badge spells out "Cancelled", so colour is never the only signal.

## 9. Out of scope

- Bulk cancel.
- Cancelling from the JARVIS briefing.
- A light theme for the boards.
