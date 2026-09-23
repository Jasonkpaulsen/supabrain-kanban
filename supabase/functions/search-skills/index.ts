import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

async function getEmbedding(text: string, apiKey: string): Promise<number[]> {
  const response = await fetch("https://api.openai.com/v1/embeddings", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: "text-embedding-3-small",
      input: text,
    }),
  });

  if (!response.ok) {
    const err = await response.text();
    throw new Error(`OpenAI API error: ${response.status} - ${err}`);
  }

  const data = await response.json();
  return data.data[0].embedding;
}

Deno.serve(async (req: Request) => {
  try {
    if (req.method === "OPTIONS") {
      return new Response("ok", {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "POST, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type, Authorization",
        },
      });
    }

    const body = await req.json();
    const query = body.query;
    const matchThreshold = body.threshold ?? 0.3;
    const matchCount = body.count ?? 5;

    if (!query || typeof query !== "string") {
      return new Response(
        JSON.stringify({ error: "Missing 'query' string in request body" }),
        { status: 400, headers: { "Content-Type": "application/json" } }
      );
    }

    const openaiKey = Deno.env.get("OPENAI_API_KEY") || body.openai_api_key;
    if (!openaiKey) {
      return new Response(
        JSON.stringify({ error: "No OpenAI API key found. Set OPENAI_API_KEY secret or pass openai_api_key in body." }),
        { status: 400, headers: { "Content-Type": "application/json" } }
      );
    }

    // Generate embedding for the search query
    const queryEmbedding = await getEmbedding(query, openaiKey);

    // Call the match_skills function
    const { data: matches, error: matchError } = await supabase.rpc(
      "match_skills",
      {
        query_embedding: JSON.stringify(queryEmbedding),
        match_threshold: matchThreshold,
        match_count: matchCount,
      }
    );

    if (matchError) {
      throw new Error(`match_skills RPC error: ${matchError.message}`);
    }

    return new Response(
      JSON.stringify({
        success: true,
        query,
        match_count: matches?.length ?? 0,
        matches: matches ?? [],
      }),
      {
        headers: {
          "Content-Type": "application/json",
          "Access-Control-Allow-Origin": "*",
        },
      }
    );
  } catch (error) {
    console.error("Error:", error);
    return new Response(
      JSON.stringify({ error: error.message }),
      {
        status: 500,
        headers: {
          "Content-Type": "application/json",
          "Access-Control-Allow-Origin": "*",
        },
      }
    );
  }
});
