import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

interface MemoryRow { id: string; type: string; summary: string | null; content: string; tags: string[] | null; }

async function getEmbedding(text: string, apiKey: string): Promise<number[]> {
  const response = await fetch("https://api.openai.com/v1/embeddings", {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${apiKey}` },
    body: JSON.stringify({ model: "text-embedding-3-small", input: text }),
  });
  if (!response.ok) { const err = await response.text(); throw new Error(`OpenAI API error: ${response.status} - ${err}`); }
  const data = await response.json();
  return data.data[0].embedding;
}

function buildEmbeddingText(m: MemoryRow): string {
  const parts = [`Type: ${m.type}`];
  if (m.summary) parts.push(`Summary: ${m.summary}`);
  parts.push(`Content: ${m.content}`);
  if (m.tags?.length) parts.push(`Tags: ${m.tags.join(", ")}`);
  return parts.join("\n");
}

Deno.serve(async (req: Request) => {
  try {
    if (req.method === "OPTIONS") {
      return new Response("ok", { headers: { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "POST, OPTIONS", "Access-Control-Allow-Headers": "Content-Type, Authorization" }});
    }
    const body = await req.json().catch(() => ({}));
    const openaiKey = Deno.env.get("OPENAI_API_KEY") || body.openai_api_key;
    if (!openaiKey) return new Response(JSON.stringify({ error: "No OpenAI API key found." }), { status: 400, headers: { "Content-Type": "application/json" } });

    const targetId = body.memory_id || null;
    const limit = Math.min(body.limit || 200, 300);

    let query = supabase.from("memories").select("id, type, summary, content, tags");
    if (targetId) query = query.eq("id", targetId); else query = query.is("embedding", null).limit(limit);
    const { data: rows, error: fetchError } = await query;
    if (fetchError) throw new Error(`Failed to fetch memories: ${fetchError.message}`);
    if (!rows || rows.length === 0) return new Response(JSON.stringify({ message: "No memories need embedding", processed: 0, remaining: 0 }), { headers: { "Content-Type": "application/json" } });

    const results = [];
    for (const m of rows) {
      try {
        const embedding = await getEmbedding(buildEmbeddingText(m as MemoryRow), openaiKey);
        const { error: updErr } = await supabase.from("memories").update({ embedding: JSON.stringify(embedding) }).eq("id", m.id);
        results.push({ id: m.id, status: updErr ? "error" : "embedded", error: updErr?.message });
      } catch (e) { results.push({ id: m.id, status: "error", error: String(e) }); }
    }
    let remaining = 0;
    if (!targetId) { const { count } = await supabase.from("memories").select("id", { count: "exact", head: true }).is("embedding", null); remaining = count || 0; }
    return new Response(JSON.stringify({ success: true, processed: results.length, remaining }), { headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" } });
  } catch (error) {
    console.error("Error:", error);
    return new Response(JSON.stringify({ error: String(error) }), { status: 500, headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" } });
  }
});
