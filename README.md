# LLM-Github-Action

The compute half of a serverless, on-demand LLM: a GitHub Actions workflow
that installs [Ollama](https://ollama.com), runs one chat completion, and
reports the result back — with nothing running the rest of the time.

The API half — an OpenAI-compatible `/v1/chat/completions` endpoint that
triggers this workflow and hands a normal HTTP response back to the caller —
lives separately, in
[sudtanj/deno-ide-playground](https://github.com/sudtanj/deno-ide-playground)'s
`llm-gateway/` module, deployed on [Deno Deploy](https://deno.com/deploy).
This repo only ever holds the pipeline; see that repo's README ("LLM
gateway" section) for the client-facing side, its setup, and its
limitations (cold start, CPU-only, no token streaming).

## How a request becomes a run

```
client --(POST /llm-gateway/v1/chat/completions)-->  deno-ide-playground
                                                          |
                                    repository_dispatch("llm-run") on this repo
                                                          v
                                    .github/workflows/llm-run.yml (this repo)
                                      - installs Ollama
                                      - pulls the requested model
                                      - runs the completion
                                                          |
                              POST back to the gateway's callback URL,
                              authenticated by a per-request HMAC token
                                                          v
client <----------- OpenAI-shaped JSON, relayed by the gateway -----------
```

`repository_dispatch` never returns a run id to poll, which is why this
workflow calls back instead of being polled: the gateway hands it a
`request_id`, a `callback_url` and a `callback_token` in the dispatch
payload, and `scripts/run-llm.sh` reports success or failure to that URL
itself, whichever it turns out to be — including on failure, via a
`trap ... EXIT`, since the gateway is holding an HTTP request open waiting
on exactly one POST back.

## Files

- **`.github/workflows/llm-run.yml`** — the `repository_dispatch` trigger
  (event type `llm-run`), Ollama install, model cache
  (`actions/cache`, keyed by model name, to avoid re-pulling on every run),
  and the call into the script below. Payload values that come from the
  dispatch (`model`, `messages`, the callback URL/token) are passed through
  as step `env:`, never interpolated directly into a `run:` script — the
  standard way to avoid GitHub Actions script injection from
  attacker-influenced input (here, an API caller's own `model`/`messages`).
- **`scripts/run-llm.sh`** — starts `ollama serve`, waits for it to be
  ready, pulls the model, and calls Ollama's own OpenAI-compatible
  `http://127.0.0.1:11434/v1/chat/completions` with the caller's messages.
  Ollama's response is already OpenAI-shaped, so it's relayed to the gateway
  essentially verbatim as the `completion` field of the callback body —
  there's no reformatting on either side of this repo's boundary.

## Setup

Nothing to configure in this repo beyond having Actions enabled — it has no
secrets of its own. Everything request-specific (which model, whose
callback, what token) arrives in the `repository_dispatch` payload from the
gateway. What the *gateway* needs is documented in its own repo:

- `LLM_GATEWAY_GITHUB_OWNER` / `LLM_GATEWAY_GITHUB_REPO` pointing at this
  repo.
- `LLM_GATEWAY_GITHUB_TOKEN` — a token with permission to dispatch workflow
  events here (a fine-grained PAT scoped to this repo with
  `Contents: Read` and `Actions: Read and write`, or a classic PAT with
  `repo` scope).

## Trying it directly (without the gateway)

For debugging, you can fire the same event `gh` or `curl` would send:

```bash
curl -X POST \
  -H "Authorization: Bearer <a token that can dispatch workflows here>" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/sudtanj/llm-github-action/dispatches \
  -d '{
    "event_type": "llm-run",
    "client_payload": {
      "request_id": "test-1",
      "model": "llama3.2:1b",
      "messages": [{"role": "user", "content": "Say hi in five words."}],
      "callback_url": "https://webhook.site/<your-test-id>",
      "callback_token": "anything, since a test endpoint won't check it"
    }
  }'
```

Then watch the run under **Actions**, and check whatever `callback_url` you
pointed at for the result.

## Limitations

See `deno-ide-playground`'s README for the full list (cold start,
CPU-only inference, no token streaming, Actions concurrency limits) — they
apply here since this is the half that actually runs the model.
