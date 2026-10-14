import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// Session 23 (2026-04-19): test-key is retired.
// Previous version leaked a partial ANTHROPIC_API_KEY fingerprint (length +
// prefix + suffix). No production use case. The function is kept as a 410 Gone
// stub until Jason deletes it from the Supabase dashboard at his convenience.
// verify_jwt is now true too, so even the stub is not publicly callable.
Deno.serve(async () => {
  return new Response(
    JSON.stringify({
      error: "Gone",
      message: "This endpoint has been retired. It was a legacy debugging tool that leaked a partial ANTHROPIC_API_KEY fingerprint. Delete the function from Supabase dashboard when convenient.",
      retired_at: "2026-04-19"
    }),
    {
      status: 410,
      headers: { "Content-Type": "application/json" }
    }
  );
});
