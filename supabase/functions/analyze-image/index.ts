import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")!;

// Session 23 (2026-04-19): post-RLS-migration fix.
// image_assets.user_id is NOT NULL since session 3. Service-role inserts have
// auth.uid() = NULL, so the table DEFAULT doesn't fire. We read the owner from
// a configurable env var so single-user today, pluggable later.
// Set OWNER_USER_ID in Supabase dashboard -> Edge Functions -> Secrets.
const OWNER_USER_ID = Deno.env.get("OWNER_USER_ID");

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

const VISION_PROMPT = `You are an image analysis assistant for a personal knowledge management system owned by a senior technology executive. Analyze this image thoroughly and return a JSON object with exactly these fields:

{
  "description": "A detailed 2-3 sentence description of what this image shows, including context and purpose",
  "tags": ["array", "of", "relevant", "tags"],
  "extracted_text": "Any text visible in the image, transcribed verbatim. Empty string if no text.",
  "image_type": "One of: screenshot, diagram, whiteboard, document, photo, receipt, business_card, other",
  "objects_detected": ["array", "of", "key", "objects", "or", "elements"]
}

Be thorough with text extraction (OCR). For diagrams, describe the architecture and relationships. For whiteboards, capture all written content. For documents, identify the document type and key information. Return ONLY valid JSON, no markdown.`;

Deno.serve(async (req: Request) => {
  try {
    // Handle CORS
    if (req.method === "OPTIONS") {
      return new Response("ok", {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "POST, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type, Authorization, x-webhook-secret",
        },
      });
    }

    // Fail fast if the owner user_id isn't configured.
    // Post-session-3 RLS requires user_id on every insert; no sensible default.
    if (!OWNER_USER_ID) {
      return new Response(
        JSON.stringify({ error: "Missing OWNER_USER_ID secret. Set it in Supabase dashboard -> Edge Functions -> Secrets." }),
        { status: 500, headers: { "Content-Type": "application/json" } }
      );
    }

    const body = await req.json();

    // Support both direct calls and webhook payloads
    let storagePath: string;
    let bucket: string;
    let originalFilename: string;

    if (body.record) {
      // Database webhook payload (from storage.objects insert)
      storagePath = body.record.name;
      bucket = body.record.bucket_id;
      originalFilename = body.record.name.split("/").pop() || body.record.name;
    } else if (body.storage_path && body.bucket) {
      // Direct invocation
      storagePath = body.storage_path;
      bucket = body.bucket;
      originalFilename = body.original_filename || storagePath.split("/").pop() || storagePath;
    } else {
      return new Response(
        JSON.stringify({ error: "Missing storage_path and bucket, or webhook record" }),
        { status: 400, headers: { "Content-Type": "application/json" } }
      );
    }

    // Skip non-image files
    const imageExtensions = [".jpg", ".jpeg", ".png", ".gif", ".webp"];
    const ext = storagePath.toLowerCase().substring(storagePath.lastIndexOf("."));
    if (!imageExtensions.includes(ext)) {
      return new Response(
        JSON.stringify({ message: "Skipped: not an image file", path: storagePath }),
        { headers: { "Content-Type": "application/json" } }
      );
    }

    // Insert pending record (session 23: user_id now required by session-3 RLS)
    const { data: assetRecord, error: insertError } = await supabase
      .from("image_assets")
      .insert({
        user_id: OWNER_USER_ID,
        storage_path: storagePath,
        storage_bucket: bucket,
        original_filename: originalFilename,
        public_url: `${SUPABASE_URL}/storage/v1/object/public/${bucket}/${storagePath}`,
        analysis_status: "processing",
      })
      .select("id")
      .single();

    if (insertError) {
      throw new Error(`Failed to insert asset record: ${insertError.message}`);
    }

    const assetId = assetRecord.id;

    // Download the image from storage
    const { data: fileData, error: downloadError } = await supabase.storage
      .from(bucket)
      .download(storagePath);

    if (downloadError || !fileData) {
      await supabase
        .from("image_assets")
        .update({ analysis_status: "failed", analysis_error: `Download failed: ${downloadError?.message}` })
        .eq("id", assetId);
      throw new Error(`Failed to download image: ${downloadError?.message}`);
    }

    // Convert to base64
    const arrayBuffer = await fileData.arrayBuffer();
    const base64 = btoa(String.fromCharCode(...new Uint8Array(arrayBuffer)));
    const fileSize = arrayBuffer.byteLength;

    // Determine media type
    const mediaTypeMap: Record<string, string> = {
      ".jpg": "image/jpeg",
      ".jpeg": "image/jpeg",
      ".png": "image/png",
      ".gif": "image/gif",
      ".webp": "image/webp",
    };
    const mediaType = mediaTypeMap[ext] || "image/jpeg";

    // Call Claude Vision API
    const claudeResponse = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: "claude-haiku-4-5-20251001",
        max_tokens: 1024,
        messages: [
          {
            role: "user",
            content: [
              {
                type: "image",
                source: {
                  type: "base64",
                  media_type: mediaType,
                  data: base64,
                },
              },
              {
                type: "text",
                text: VISION_PROMPT,
              },
            ],
          },
        ],
      }),
    });

    if (!claudeResponse.ok) {
      const errorText = await claudeResponse.text();
      await supabase
        .from("image_assets")
        .update({
          analysis_status: "failed",
          analysis_error: `Claude API error: ${claudeResponse.status} - ${errorText}`,
          file_size_bytes: fileSize,
          mime_type: mediaType,
        })
        .eq("id", assetId);
      throw new Error(`Claude API error: ${claudeResponse.status} - ${errorText}`);
    }

    const claudeData = await claudeResponse.json();
    const analysisText = claudeData.content[0].text;

    // Parse Claude's JSON response
    let analysis;
    try {
      analysis = JSON.parse(analysisText);
    } catch {
      // Try to extract JSON from the response if it has extra text
      const jsonMatch = analysisText.match(/\{[\s\S]*\}/);
      if (jsonMatch) {
        analysis = JSON.parse(jsonMatch[0]);
      } else {
        throw new Error(`Failed to parse Claude response as JSON: ${analysisText}`);
      }
    }

    // Update the asset record with analysis results
    const { error: updateError } = await supabase
      .from("image_assets")
      .update({
        description: analysis.description || null,
        tags: analysis.tags || [],
        extracted_text: analysis.extracted_text || null,
        image_type: analysis.image_type || "other",
        objects_detected: analysis.objects_detected || [],
        file_size_bytes: fileSize,
        mime_type: mediaType,
        analysis_status: "completed",
        meta: {
          claude_model: "claude-haiku-4-5-20251001",
          analyzed_at: new Date().toISOString(),
          input_tokens: claudeData.usage?.input_tokens,
          output_tokens: claudeData.usage?.output_tokens,
        },
      })
      .eq("id", assetId);

    if (updateError) {
      throw new Error(`Failed to update asset record: ${updateError.message}`);
    }

    return new Response(
      JSON.stringify({
        success: true,
        asset_id: assetId,
        analysis: {
          description: analysis.description,
          tags: analysis.tags,
          image_type: analysis.image_type,
          extracted_text: analysis.extracted_text ? "[text extracted]" : "[no text]",
          objects_detected: analysis.objects_detected,
        },
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
