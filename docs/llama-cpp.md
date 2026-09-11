# llama.cpp

CPU-only, OpenAI-compatible inference server running in **router mode**: it
serves every `.gguf` model found under its models directory and loads a
model on demand when it is first requested, instead of being fixed to one
model. Its container listens on port `8080` internally; DockTail publishes
it as the private Tailscale Service `llama` on HTTPS port `443`. No host
port is published.

## Requirements

- One or more `.gguf` models in `/mnt/ssd/homelab/apps/llama-cpp/models/`
  (a single file per model, or a subdirectory for multimodal/multi-shard
  models) — see [prerequisites](prerequisites.md#3-llamacpp-models).
- The API key in `/mnt/ssd/homelab/apps/llama-cpp/.env`.
- A client using `Authorization: Bearer <LLAMA_API_KEY>`.

Each model's ID is its filename without the `.gguf` extension (or its
subdirectory name). Open `https://llama.<tailnet>.ts.net` in a browser to
use the built-in web UI, which lists the staged models and loads the
selected one automatically. API clients pick a model the same way, by name,
in the `"model"` field.

## Defaults

| Setting | Default | Env var |
|---|---|---|
| Context size | 4096 tokens | `LLAMA_CTX_SIZE` |
| CPU threads | 4 | `LLAMA_THREADS` |
| Parallel request slots per model | 1 | `LLAMA_N_PARALLEL` |
| Models loaded at once | 1 | `LLAMA_MODELS_MAX` |

`LLAMA_MODELS_MAX=1` keeps a second model from ever loading onto the Pi's
limited RAM while another is already resident. Benchmark a model before
raising `LLAMA_MODELS_MAX` or the other defaults. Edit the runtime `.env`
and run `sudo ./setup.sh reconcile llama-cpp` to apply changes.

## Test

```sh
LLAMA_URL=https://llama.<tailnet>.ts.net
LLAMA_API_KEY='value from /mnt/ssd/homelab/apps/llama-cpp/.env'
curl --fail "$LLAMA_URL/health"
curl --fail -H "Authorization: Bearer $LLAMA_API_KEY" "$LLAMA_URL/models"
curl --fail \
  -H "Authorization: Bearer $LLAMA_API_KEY" \
  -H "Content-Type: application/json" \
  "$LLAMA_URL/v1/chat/completions" \
  -d '{"model":"<id from /models>","messages":[{"role":"user","content":"Reply with one word: ready"}],"max_tokens":8}'
```

## Add, replace, or remove a model

Copy the new verified `.gguf` file (or subdirectory) into the models
directory, then make the router pick it up without restarting the
container:

```sh
curl --fail -H "Authorization: Bearer $LLAMA_API_KEY" "$LLAMA_URL/models?reload=1"
```

Remove an old model the same way: delete it from the models directory, then
reload. Keep the old model staged until the new one passes the `/health` and
`/v1/chat/completions` checks above.

The API is reachable only through Tailscale. Do not add a host port, Funnel
label, or llama.cpp tools/MCP configuration.
