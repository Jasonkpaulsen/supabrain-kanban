import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

interface SkillRow {
  id: string;
  skill_id: string;
  name: string;
  description: string;
  rules: string[];
  examples: string[];
  tags: string[];
}

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

function buildEmbeddingText(skill: SkillRow): string {
  const parts = [
    `Skill: ${skill.name}`,
    `Description: ${skill.description}`,
  ];
  if (skill.rules?.length) {
    parts.push(`Rules: ${skill.rules.join(". ")}`);
  }
  if (skill.examples?.length) {
    parts.push(`Examples: ${skill.examples.join(". ")}`);
  }
  if (skill.tags?.length) {
    parts.push(`Tags: ${skill.tags.join(", ")}`);
  }
  return parts.join("\n");
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

    // Use env var first, fall back to request body
    const openaiKey = Deno.env.get("OPENAI_API_KEY") || body.openai_api_key;
    if (!openaiKey) {
      return new Response(
        JSON.stringify({ error: "No OpenAI API key found. Set OPENAI_API_KEY secret or pass openai_api_key in body." }),
        { status: 400, headers: { "Content-Type": "application/json" } }
      );
    }

    // Optional: embed a single skill by skill_id, or all skills missing embeddings
    const targetSkillId = body.skill_id || null;

    let query = supabase
      .from("skills")
      .select("id, skill_id, name, description, rules, examples, tags")
      .eq("archived", false);

    if (targetSkillId) {
      query = query.eq("skill_id", targetSkillId);
    } else {
      // Only process skills without embeddings
      query = query.is("embedding", null);
    }

    const { data: skills, error: fetchError } = await query;

    if (fetchError) {
      throw new Error(`Failed to fetch skills: ${fetchError.message}`);
    }

    if (!skills || skills.length === 0) {
      return new Response(
        JSON.stringify({ message: "No skills need embedding", processed: 0 }),
        { headers: { "Content-Type": "application/json" } }
      );
    }

    const results = [];

    for (const skill of skills) {
      const text = buildEmbeddingText(skill);
      const embedding = await getEmbedding(text, openaiKey);

      const { error: updateError } = await supabase
        .from("skills")
        .update({
          embedding: JSON.stringify(embedding),
          vector_id: skill.id,
        })
        .eq("id", skill.id);

      if (updateError) {
        results.push({ skill_id: skill.skill_id, name: skill.name, status: "error", error: updateError.message });
      } else {
        results.push({ skill_id: skill.skill_id, name: skill.name, status: "embedded", dimensions: embedding.length });
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        processed: results.length,
        results,
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
