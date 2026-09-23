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
| Context size | 65536 tokens (64k) | `LLAMA_CTX_SIZE` |
| CPU threads | 4 | `LLAMA_THREADS` |
| Parallel request slots per model | 1 | `LLAMA_N_PARALLEL` |
| Models loaded at once | 1 | `LLAMA_MODELS_MAX` |
| KV cache quantization (K and V) | `q8_0` | `LLAMA_CACHE_TYPE` |

`LLAMA_MODELS_MAX=1` keeps a second model from ever loading onto the Pi's
limited RAM while another is already resident. Benchmark a model before
raising `LLAMA_MODELS_MAX` or the other defaults. Edit the runtime `.env`
and run `sudo ./setup.sh reconcile llama-cpp` to apply changes.

The 64k context default exists because
[hermes-agent](hermes-agent.md#model-provider-the-existing-llamacpp-server)
hard-requires a model context window of at least 64,000 tokens and refuses
to use anything smaller. `LLAMA_CACHE_TYPE=q8_0` quantizes the KV cache to
8 bits (K and V) instead of llama.cpp's f16 default — this is what makes
64k affordable on the Pi's 16GB: KV cache RAM scales linearly as
`2 (K+V) × attention_layers × kv_heads × head_dim × ctx_size × bytes_per_element`,
so doubling `ctx_size` and halving `bytes_per_element` roughly cancel out.
Quality loss from `q8_0` KV cache is negligible versus f16; it is not the
same as quantizing the model weights.

**Check the math before staging a new model.** At 64k context with f16 KV
cache (the pre-`LLAMA_CACHE_TYPE` default), a dense ~4B model with GQA
(e.g. Qwen3-4B: 36 layers, 8 KV heads, head_dim 128) needs roughly 9.7GB for
KV cache alone — combined with weights and compute buffers that leaves
**no headroom** on a 16GB Pi already running Docker, Tailscale, and the
other containers here. With `q8_0` KV cache that drops to ~4.8GB, which
fits with a few GB to spare. Hybrid/SSM-leaning architectures (e.g. LFM2)
need far less, because only their attention layers carry a KV cache — most
of their layers use a small fixed-size state that doesn't grow with
context. Before raising context or `LLAMA_MODELS_MAX` further, compute (or
re-derive from the model's `config.json`: `num_hidden_layers`,
`num_key_value_heads`, `head_dim`) the KV cache size for the *largest*
staged model and confirm `model weights + KV cache + ~0.5–1GB compute
buffer + ~3GB baseline OS/Docker/other-containers` stays comfortably under
16GB. `LLAMA_MODELS_MAX=1` means only the sizing of the single
largest/most expensive model matters, not the sum of all staged models.

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
