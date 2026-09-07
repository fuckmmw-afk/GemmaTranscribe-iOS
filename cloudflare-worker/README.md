# GemmaTranscribe Cloudflare Brain Worker

Cloudflare Worker providing post-STOP AI processing, web search (Wikipedia API), and structured card synthesis.

## Features
- Receives clean plaintext transcript (audio is NEVER transmitted).
- Extracts key topics and conducts realtime web search via Wikipedia API.
- Synthesizes findings using Cloudflare Workers AI (`@cf/meta/llama-3.1-8b-instruct`).
- Returns structured JSON containing summary, cards, notes, sources, and action points.

## Deployment
```bash
cd cloudflare-worker
npx wrangler deploy
```

Once deployed, copy the worker URL into the GemmaTranscribe app Settings!
