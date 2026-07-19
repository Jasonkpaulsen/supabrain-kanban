// Not-yet-built views (Codex, Timeline, Map, Portal, …). Honest about roadmap status
// rather than faking screens — the recording critical path ships first (EPIC CIP-155).
export default function Placeholder({ title }: { title: string }) {
  return (
    <div>
      <h1>{title}</h1>
      <section className="card empty">
        <p className="muted">
          <strong>{title}</strong> arrives after the recording pipeline lands. Sessions you capture
          now become the source material this view is built from.
        </p>
        <p className="muted small">Roadmap: EPIC CIP-155 (Authored Adventures V1.1).</p>
      </section>
    </div>
  );
}
