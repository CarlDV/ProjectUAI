# Provider compatibility and WebSockets

Applies to **1.9.0**, September 26, 2026.

UAI implements two inference protocols: **Chat Completions** and **Anthropic
Messages**. A provider works through one of these APIs, including when it is a
local server or a relay. This is protocol compatibility, not a guarantee that
every model, server version, account or proprietary API works.

The compatibility checks use synthetic HTTP responses and socket events. They
need no running models, API keys or paid inference. Live server availability,
model quality, tool-call accuracy, executor networking and TLS are outside that
coverage.

## Local servers

Leave **Gateway socket URL** empty for these ordinary HTTP connections.

| Server / preset | Default base URL | Authentication | Tool requirements |
| --- | --- | --- | --- |
| Ollama | `http://127.0.0.1:11434/v1` | None for local models | A model supporting tools. UAI omits default `tool_choice` and `parallel_tool_calls`; explicit overrides remain possible. |
| LM Studio | `http://127.0.0.1:1234/v1` | None by default; Bearer if server auth is enabled | A suitable model and chat template; support varies by model/runtime. |
| vLLM | `http://127.0.0.1:8000/v1` | None by default; Bearer if `--api-key` is configured | A chat template, an appropriate tool-call parser and automatic tool choice enabled on the server. |
| llama.cpp | `http://127.0.0.1:8080/v1` | None by default; Bearer if `--api-key` is configured | A compatible model/template, often with `--jinja`; parser support depends on the model. |
| SGLang | `http://127.0.0.1:30000/v1` | None by default; Bearer when server auth is configured | The model's chat template and tool-call parser. |
| Other compatible servers/proxies | Enter their documented base URL under Custom endpoint | Match the server configuration | Must implement one of UAI's two protocols, including tool-result replay for agent use. |

The local preset label does not decide reachability. UAI checks the actual URL:
loopback, private IPv4/IPv6, `.localhost`, `.local` and single-label hosts require
an executor HTTP function. A public URL entered in a local preset is treated as
public; a custom localhost URL is treated as local. `localhost` refers to the
machine making the request. A remote container, VM or LAN server needs its
reachable address and port. A server's bind address such as `0.0.0.0` is not the
normal client address; use loopback or its actual interface address.

Fetch models after the server is running, or enter its exact model/deployment id.
UAI does not invent model names or hide embedding models returned by discovery.
An ordinary text reply does not prove tool support. Agent use also needs a model
and context window large enough for the selected tools and conversation.

Ollama's native `/api/chat` and `/api/generate`, Gemini `generateContent`, OpenAI
Responses/Realtime, legacy Completions, Bedrock's native API and other proprietary
formats are not adapters in this client. Use a compatible surface or an external
adapter. Known mismatched native paths produce an actionable diagnostic.

## Preset routing matrix

These are the catalog routes exercised by the offline preset matrix. Except for
the classic Azure deployment API, the configured model id is sent in the request.
`/models` is discovered under the same base; if a service does not expose it or
the key cannot list models, manual ids remain usable.

| Preset | Base path / host | Protocol | Default auth |
| --- | --- | --- | --- |
| HCNSEC | `api.hcnsec.cn/v1` | Chat Completions | Bearer |
| AgentRouter | `agentrouter.org/v1` | Messages | x-api-key |
| OpenAI | `api.openai.com/v1` | Chat Completions | Bearer |
| OpenRouter | `openrouter.ai/api/v1` | Chat Completions | Bearer |
| OpenCode Zen | `opencode.ai/zen/v1` | Chat Completions | Bearer |
| Azure AI Foundry | `<resource>.openai.azure.com/openai/v1` | Chat Completions | api-key |
| Anthropic Messages | `api.anthropic.com/v1` | Messages | x-api-key |
| Anthropic OpenAI compatibility | `api.anthropic.com/v1` | Chat Completions | x-api-key |
| Google Gemini compatibility | `generativelanguage.googleapis.com/v1beta/openai` | Chat Completions | Bearer |
| Groq | `api.groq.com/openai/v1` | Chat Completions | Bearer |
| DeepSeek | `api.deepseek.com/v1` | Chat Completions | Bearer |
| Together AI | `api.together.xyz/v1` | Chat Completions | Bearer |
| Mistral | `api.mistral.ai/v1` | Chat Completions | Bearer |
| xAI | `api.x.ai/v1` | Chat Completions | Bearer |
| Fireworks | `api.fireworks.ai/inference/v1` | Chat Completions | Bearer |
| Cerebras | `api.cerebras.ai/v1` | Chat Completions | Bearer |
| Azure OpenAI deployment | `<resource>.openai.azure.com/openai/deployments/<deployment>` | Chat Completions, model from URL | api-key; `api-version` query |
| Ollama / LM Studio / vLLM / llama.cpp / SGLang | Local URLs above | Chat Completions | None |
| Custom endpoint | User-entered | User-selected | Bearer initially; configurable |

Relays can impose account, model or official-client restrictions that an adapter
does not remove. Discovery is not authorization to use every listed model.

## Connection and response behavior

- A bare public hostname gains `https://` and, if no path exists, `/v1`. Bare local
  addresses gain `http://`. An explicit scheme and custom prefix are preserved.
  IPv6 addresses use brackets. Unsupported schemes and URL userinfo are rejected.
- Full `/chat/completions` or `/messages` URLs work, including query strings;
  switching protocol or discovering models replaces the endpoint suffix. URL
  fragments are omitted. Extra query fields override a same-named base query
  field without duplicating it, and other base query values are preserved.
- Auth styles are literal: Bearer, x-api-key, api-key, both, or none. Native
  Anthropic presets select x-api-key; an explicit Bearer choice is honored for
  Messages gateways. Key pools choose one credential for discovery and inference.
  Later header maps override earlier names case-insensitively.
- Discovered ids are cached for ten minutes for that connection/auth configuration.
  Unsaved drafts are separate. Changing settings, invalidating or starting a newer
  fetch prevents an older response from overwriting the list. HTTP error documents
  are not successful empty model lists. Manually entered models remain first.
- The provider editor clears fetched choices when its URL, protocol, auth, key or
  preset changes, including changing away and back during a pending fetch. Manual
  ids remain available. Choosing a preset applies its identity defaults and clears
  the previous preset's gateway URL; local presets link to server setup docs.
- JSON and buffered SSE use one bounded Chat Completions assembler. Text,
  reasoning, usage and indexed tool-argument fragments survive; a whole argument
  object is serialized to JSON. Mixed object/fragment arguments fail visibly.
  Corrupt or incomplete streams cannot become successful replies.
- Clear 400/422 parameter refusals can teach bounded request repairs. FastAPI
  validation errors expose field locations/messages without echoing their `input`.
  Repairs and learned output limits follow the endpoint, protocol and model;
  old unscoped lessons adopt the current configuration on first use. Context
  refusals naming at least 512 tokens are recognized, including 2K/4K local models.
  Learned context windows retain the existing global, lowercased model-id map.
- HTTP is buffered by the Roblox/executor API. Selecting SSE does not make that
  transport incremental. Native HTTP/socket requests have a maximum 300-second
  wait and 8 MiB response budget; the host/server may impose shorter limits.
  The removed 8,192-token executor ceiling does not return on HTTP fallback.

## Exactly how the WebSocket option works

It is an optional **UAI gateway protocol**, not the provider's normal HTTP API.
No matching inference WebSocket gateway ships in `bridge/` or `tools/`. The
optional browser bridge uses its own relay protocol and is a separate transport.

```mermaid
sequenceDiagram
    participant U as UAI Chat Completions adapter
    participant W as Configured UAI WebSocket gateway
    participant P as Gateway's configured provider
    U->>W: Connect to wsUrl (one socket per completion)
    U->>W: JSON {path, headers, body}
    W->>P: POST provider origin + path, using headers and body
    P-->>W: Chat Completions chunks
    W-->>U: JSON chunks or SSE data events
    W-->>U: [DONE], or finish_reason followed by close
    U->>U: Assemble final reply; disconnect callbacks and close
```

1. The adapter uses the socket only for Chat Completions when the effective body
   has `stream: true`, `wsUrl` is set, an executor connector exists, and the web
   relay is not selected. Discovery remains HTTP. Messages ignores `wsUrl`.
2. UAI calls `connect(wsUrl)` with **no custom upgrade headers**. A gateway requiring
   custom HTTP authentication headers during the WebSocket handshake is not
   supported by this connector. The gateway receives provider credentials in the
   first application message instead.
3. UAI sends one JSON envelope, for example:

   ```json
   {
     "path": "/proxy/v1/chat/completions?api-version=example",
     "headers": {
       "Authorization": "Bearer <provider-key>",
       "Content-Type": "application/json",
       "Accept": "text/event-stream"
     },
     "body": {
       "model": "server-model-id",
       "messages": [{"role": "user", "content": "Hello"}],
       "stream": true
     }
   }
   ```

   `path` is the complete provider path and query, with no origin. The gateway
   needs its own configured upstream origin; UAI does not choose that upstream
   for it. Headers use the same auth, custom fields and required identity as HTTP.
   A gateway therefore sees the provider key, prompt and tools.
4. Replies may be individual Chat Completions JSON objects or SSE events. SSE
   comments/metadata, CRLF, multiline data and events split/combined across socket
   messages are accepted. A complete single `data: {...}` message without a blank
   separator remains supported. Each accepted chunk updates the live preview and
   is retained for final assembly.
5. `[DONE]` completes the exchange. A close following a valid `finish_reason`
   also succeeds. Closing mid-event or before completion, invalid JSON, provider
   error events, callback failures and exceeded budgets fail the request. A stream
   with no data is not a success.
6. Connect/setup failures, a connector unavailable before dispatch, or a connection
   deadline before `Send` permit HTTP fallback. After entering `Send`, delivery may
   have happened even if the call raises: timeout, cancellation, malformed data
   and premature close are terminal. They cannot silently retry by HTTP or another
   provider. Late connections are closed without sending; late callbacks are
   disconnected and cannot update the transcript.

Limits are four connection/send workers and four reserved active connections,
1–300 seconds per attempt (120 seconds when called directly without a timeout),
8 MiB of received data, 1 MiB per SSE/JSON event, 10,000 socket messages/events,
64 tool calls and 256,000 argument bytes per tool call. A completion creates and
closes its own socket; chats do not share a permanent connection.

OpenAI's documented Responses WebSocket mode instead connects to `/v1/responses`,
authenticates during connection and sends `response.create` events. Its event
schema and connection state are different. Realtime is another API again. Neither
can receive the UAI envelope above without an adapter.

## Offline verification

Implementation and regression fixtures are written before running the tests.
The focused suites cover every catalog preset's routes/auth, JSON and SSE,
tool-call/result replay, local compatibility failures, discovery races in both the
model service and provider editor, scoped repairs, socket framing, cleanup and
dispatch/fallback boundaries.

```powershell
luajit test/provider_compatibility.lua
luajit test/provider_transport.lua
luajit test/provider_editor.lua
node tools/test_native.js
```

The full native command rebuilds the bundle, checks generated artifacts, runs the
main/focused suites and performance contracts, then compiles with official Luau.
Results and any remaining limitations are recorded in
[the native release report](NATIVE_COMPLETION.md).

Published protocol references consulted September 25, 2026:

- [Ollama OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility)
- [LM Studio compatibility](https://lmstudio.ai/docs/developer/openai-compat),
  [tools](https://lmstudio.ai/docs/developer/openai-compat/tools) and
  [authentication](https://lmstudio.ai/docs/developer/core/authentication)
- [vLLM online serving](https://docs.vllm.ai/en/latest/serving/online_serving/)
- [llama.cpp server documentation](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- [SGLang OpenAI-compatible APIs](https://docs.sglang.io/docs/basic_usage/openai_api_completions.md)
- [OpenAI Responses WebSocket mode](https://developers.openai.com/api/docs/guides/websocket-mode)
