/**
 * GemmaTranscribe Cloudflare Brain Worker
 *
 * Receives cleaned plaintext transcripts after STOP.
 * Performs web search (Wikipedia API) + Cloudflare Workers AI structured analysis.
 * NOTE: Never receives audio; receives cleaned plaintext only.
 */

export default {
  async fetch(request, env, ctx) {
    // Handle CORS preflight
    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "POST, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type",
        },
      });
    }

    if (request.method !== "POST") {
      return new Response(JSON.stringify({ error: "Method not allowed. Use POST." }), {
        status: 405,
        headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
      });
    }

    try {
      const body = await request.json();
      const rawTranscript = (body.raw_transcript || "").trim();
      const locale = body.locale || "ru";

      if (!rawTranscript) {
        return new Response(JSON.stringify({
          summary: "Empty transcript",
          cards: [],
          action_points: [],
          web_search: null,
          searched: false
        }), {
          headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
        });
      }

      // 1. Web Search Execution (Wikipedia API)
      const searchQuery = extractSearchQuery(rawTranscript);
      const searchResult = await performWebSearch(searchQuery, locale);

      // 2. Cloudflare Workers AI Synthesis
      let aiResult = null;
      if (env.AI) {
        aiResult = await runWorkersAI(env.AI, rawTranscript, searchResult, locale);
      } else {
        aiResult = generateLocalHeuristicResponse(rawTranscript, searchResult);
      }

      return new Response(JSON.stringify({
        summary: aiResult.summary,
        cards: aiResult.cards,
        action_points: aiResult.actionPoints,
        web_search: searchResult ? {
          query: searchQuery,
          title: searchResult.title,
          snippet: searchResult.snippet,
          url: searchResult.url,
        } : null,
        model: aiResult.model || "@cf/meta/llama-3.1-8b-instruct",
        searched: searchResult !== null,
      }), {
        headers: {
          "Content-Type": "application/json",
          "Access-Control-Allow-Origin": "*",
        },
      });
    } catch (err) {
      return new Response(JSON.stringify({ error: err.message }), {
        status: 500,
        headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
      });
    }
  },
};

/**
 * Extracts a concise search query term from speech transcript.
 */
function extractSearchQuery(text) {
  const words = text
    .replace(/[,\.!\?:;"'—\-]/g, " ")
    .split(/\s+/)
    .filter(w => w.length > 3);

  // Take top 1-3 prominent words
  return words.slice(0, 3).join(" ") || "Обзор";
}

/**
 * Executes a web search via Wikipedia API.
 */
async function performWebSearch(query, locale = "ru") {
  try {
    const wikiDomain = locale.startsWith("en") ? "en.wikipedia.org" : "ru.wikipedia.org";
    const searchUrl = `https://${wikiDomain}/w/api.php?action=opensearch&search=${encodeURIComponent(query)}&limit=1&namespace=0&format=json`;

    const res = await fetch(searchUrl, {
      headers: { "User-Agent": "GemmaTranscribe-Worker/1.0" },
    });

    if (!res.ok) return null;
    const data = await res.json();
    // Format: [query, [titles], [descriptions], [urls]]
    if (data && data[1] && data[1].length > 0) {
      return {
        title: data[1][0],
        snippet: data[2][0] || "",
        url: data[3][0] || `https://${wikiDomain}/wiki/${encodeURIComponent(data[1][0])}`,
      };
    }
    return null;
  } catch {
    return null;
  }
}

/**
 * Calls Cloudflare Workers AI model.
 */
async function runWorkersAI(aiBinding, transcript, searchResult, locale) {
  const model = "@cf/meta/llama-3.1-8b-instruct";

  const searchContext = searchResult
    ? `Дополнительная справочная информация из поиска:\nИсточник: ${searchResult.title} (${searchResult.url})\nОписание: ${searchResult.snippet}\n`
    : "";

  const systemPrompt = `Ты — экспертный аналитический AI-ассистент в приложении GemmaTranscribe.
Твоя задача — получить расшифрованную стенограмму речи, структурировать её и обогатить найденной информацией.
Формат ответа СТРОГО в валидном JSON виде со следующими полями:
{
  "summary": "Краткое саммари (1-2 предложения)",
  "cards": [
    {
      "term": "Ключевое понятие или тезис",
      "definition": "Четкое и понятное определение или факт",
      "notes": ["Важная деталь 1", "Контекст 2"],
      "source": "Ссылка или название источника"
    }
  ],
  "actionPoints": ["Пункт действия 1", "Пункт действия 2"]
}
Не добавляй никакого текста до или после JSON. Язык ответа: ${locale.startsWith("en") ? "English" : "Russian"}.`;

  const userPrompt = `${searchContext}\nСтенограмма речи:\n"${transcript}"`;

  try {
    const response = await aiBinding.run(model, {
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userPrompt },
      ],
      temperature: 0.2,
      max_tokens: 800,
    });

    const content = response.response || "";
    // Parse JSON
    const jsonMatch = content.match(/\{[\s\S]*\}/);
    if (jsonMatch) {
      const parsed = JSON.parse(jsonMatch[0]);
      return {
        summary: parsed.summary || "",
        cards: (parsed.cards || []).map(c => ({
          term: c.term || "Ключевой тезис",
          definition: c.definition || "",
          notes: c.notes || [],
          source: c.source || searchResult?.url || "",
        })),
        actionPoints: parsed.actionPoints || [],
        model: model,
      };
    }
  } catch (err) {
    console.error("Workers AI error:", err);
  }

  return generateLocalHeuristicResponse(transcript, searchResult);
}

function generateLocalHeuristicResponse(transcript, searchResult) {
  return {
    summary: transcript.length > 120 ? transcript.slice(0, 120) + "..." : transcript,
    cards: [
      {
        term: searchResult ? searchResult.title : "Основная мысль",
        definition: searchResult ? searchResult.snippet : "Стенограмма успешно зафиксирована и очищена.",
        notes: [
          "Очищено от пауз и повторов на устройстве.",
          searchResult ? `Найден источник: ${searchResult.title}` : "Сохранено в локальной истории.",
        ],
        source: searchResult ? searchResult.url : "",
      },
    ],
    actionPoints: [
      "Проверить зафиксированные детали стенограммы",
    ],
    model: "Cloudflare Brain Pipeline",
  };
}
