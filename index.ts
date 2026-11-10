import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...corsHeaders, "Content-Type": "application/json" },
});

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ error: "Méthode non autorisée." }, 405);

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) return reply({ error: "Connexion requise." }, 401);
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false, autoRefreshToken: false } },
    );
    const { data: { user }, error: userError } = await supabase.auth.getUser();
    if (userError || !user) return reply({ error: "Session invalide." }, 401);

    const { data: profile, error: profileError } = await supabase
      .from("profiles").select("actif").eq("id", user.id).single();
    if (profileError || !profile?.actif) return reply({ error: "Compte inactif ou profil introuvable." }, 403);

    const apiKey = Deno.env.get("GEMINI_API_KEY");
    if (!apiKey) return reply({ error: "La clé Gemini n'est pas configurée côté serveur." }, 500);
    const body = await req.json();
    const question = String(body.question ?? "").trim();
    let conversationId = body.conversationId ? String(body.conversationId) : null;
    if (!question || question.length > 4000) return reply({ error: "La question doit contenir entre 1 et 4 000 caractères." }, 400);

    if (conversationId) {
      const { data: conv, error } = await supabase.from("chat_conversations")
        .select("id").eq("id", conversationId).eq("user_id", user.id).maybeSingle();
      if (error || !conv) return reply({ error: "Conversation introuvable." }, 404);
    } else {
      const { data: conv, error } = await supabase.from("chat_conversations")
        .insert({ user_id: user.id, titre: question.slice(0, 90) }).select("id").single();
      if (error) throw error;
      conversationId = conv.id;
    }

    const { error: saveQuestionError } = await supabase.from("chat_messages").insert({
      conversation_id: conversationId, role: "user", contenu: question,
    });
    if (saveQuestionError) throw saveQuestionError;

    const { data: history, error: historyError } = await supabase.from("chat_messages")
      .select("role, contenu").eq("conversation_id", conversationId)
      .order("created_at", { ascending: false }).limit(12);
    if (historyError) throw historyError;

    const contents = (history ?? []).reverse().map((m) => ({
      role: m.role === "assistant" ? "model" : "user",
      parts: [{ text: m.contenu }],
    }));
    const model = Deno.env.get("GEMINI_MODEL") || "gemini-2.5-flash";
    const prompt = `Tu es l'assistant de La Cave Impériale. Réponds en français par défaut.
` +
      `Utilise Google Search pour les faits récents ou vérifiables. Ne prétends pas consulter ` +
      `les données privées de la cave. Distingue faits et incertitudes. Lorsque Google Search ` +
      `fournit des sources, conserve les références dans les métadonnées et ne fabrique aucun lien.`;

    const gemini = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${encodeURIComponent(apiKey)}`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        system_instruction: { parts: [{ text: prompt }] },
        contents,
        tools: [{ google_search: {} }],
        generationConfig: { temperature: 0.4, maxOutputTokens: 2500 },
      }),
    });
    const result = await gemini.json();
    if (!gemini.ok) {
      console.error("Gemini API status", gemini.status, result?.error?.message);
      return reply({ error: "Gemini n'a pas pu répondre. Vérifie la clé API, le quota et le modèle." }, 502);
    }
    const candidate = result.candidates?.[0];
    const answer = (candidate?.content?.parts ?? []).map((p: {text?: string}) => p.text ?? "").join("
").trim();
    if (!answer) return reply({ error: "Gemini n'a retourné aucune réponse exploitable." }, 502);

    const grounding = candidate?.groundingMetadata ?? {};
    const chunks = grounding.groundingChunks ?? [];
    // Conserver l'ordre des chunks : groundingSupports référence leurs indices.
    const sources = chunks.filter((c: any) => c.web?.uri).map((c: any) => ({
      title: c.web.title || c.web.uri, url: c.web.uri,
    }));
    const supports = (grounding.groundingSupports ?? []).map((item: any) => ({
      segment: item.segment,
      groundingChunkIndices: item.groundingChunkIndices ?? [],
    })).filter((item: any) => Number.isInteger(item.segment?.startIndex) && Number.isInteger(item.segment?.endIndex));
    const searchEntryPoint = grounding.searchEntryPoint?.renderedContent ?? null;

    const { error: saveAnswerError } = await supabase.from("chat_messages").insert({
      conversation_id: conversationId, role: "assistant", contenu: answer,
    });
    if (saveAnswerError) throw saveAnswerError;
    if (sources.length) {
      const { error: logError } = await supabase.from("web_search_logs").insert({
        conversation_id: conversationId, user_id: user.id,
        fournisseur: "Google Search via Gemini", requete: question,
        resultats: sources, nombre_resultats: sources.length,
      });
      if (logError) console.error("Search log error", logError.message);
    }
    return reply({ answer, sources, supports, searchEntryPoint, conversationId });
  } catch (error) {
    console.error("cave-chat error", error);
    return reply({ error: "Erreur interne du chatbot. Réessaie dans un instant." }, 500);
  }
});
