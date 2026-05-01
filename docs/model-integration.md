# Model Integration

## Model surfaces in the app

The app uses model integration in three places:

- Screenshot analysis
  Categorize a screenshot and generate a short item summary.
- Daily report summarization
  Generate a daily summary and per-category summaries from structured activity text.
- Daily work-block summarization
  Merge contiguous same-category item summaries into one hover summary for the daily report heatmap.

These two features use separate settings and may use different providers.
Daily reports and daily work-block summaries both use the work-content summary profile.

## Supported providers

- OpenAI-compatible endpoint
- Anthropic-compatible endpoint
- LM Studio API
- Apple Intelligence through `FoundationModels`

## Shared integration layer

`LLMService.swift` is the single provider adapter used by both screenshot analysis and daily report summarization.

It is responsible for:

- building provider-specific requests
- normalizing text, timing, finish-reason, reasoning, and token-usage fields
- handling Apple Intelligence plain-text and guided-generation calls
- exposing a provider contract summary through `LLMService.providerContract(for:)`

LM Studio keeps one extra helper layer in `LMStudioAPI.swift` because the app also uses LM Studio's native model-management endpoints.
Model lifecycle calls are intentionally kept outside `LLMService.send(_:)`: feature services can explicitly load an LM Studio model before sending chat requests when the per-profile lifecycle toggle is enabled, or skip lifecycle calls when the selected model is already resident in the background.
Manual force-unload actions use the same lifecycle helper with a nil `instanceID`, which makes `LMStudioModelLifecycle` re-query `GET /api/v1/models` and resolve the currently loaded instance by model name plus context length instead of trusting any cached app-side loaded state.

## Screenshot analysis modes

### OCR-first mode

Used when `imageAnalysisMethod == .ocr`.

Behavior:

- Run local Vision OCR on the screenshot.
- Build a text prompt from recognized text, category rules, and summary instructions.
- Send text only to the configured remote provider.

Strengths:

- Lower payload size.
- Works with text-heavy screens such as IDEs, terminals, documentation, and chat windows.
- Enables a local-first Apple Intelligence path.

Tradeoffs:

- Weaker on visually complex layouts.
- Can fail when OCR extracts little or noisy text.

### Multimodal mode

Used when `imageAnalysisMethod == .multimodal` and the provider is remote.

Behavior:

- Send the screenshot image plus instructions to the remote endpoint.
- Parse a structured category-and-summary response from model output.

Strengths:

- Better for visual context beyond pure text.

Tradeoffs:

- Larger payloads.
- Depends on a model endpoint that actually supports image input in the expected format.

## Apple Intelligence behavior

Apple Intelligence is currently integrated as a text-based local path.

For screenshot analysis:

- The app always runs local OCR first.
- The recognized text is passed into `LanguageModelSession`.
- The model is used with the `.contentTagging` use case.

For daily summaries:

- The app sends the daily activity prompt directly as text.
- The model is used with the `.general` use case.
- Reportable activity rows must already have non-empty analysis summaries before they are included; the prompt does not synthesize compatibility placeholder text for old summary-less rows.

Important constraint:

- The current implementation does not send screenshot image bytes directly into `FoundationModels`.
- In practice, Apple Intelligence should be treated as an OCR-first local analysis option in this project.

## Daily work-block summary prompts

Daily work-block summary prompts are intentionally narrower than full daily-report prompts:

- one request summarizes exactly one contiguous block
- the request includes category name and source summary text only
- the request does not include explicit timestamps, dates, durations, or source item identifiers
- the response contract is a single JSON object: `{"summary":"..."}`

The service stores a single source item's existing summary directly. For multi-item blocks, it calls the model only when at least two source items have non-empty summaries; blocks that only have classification labels or too little summary text are skipped and logged as ignorable summary events.

## Provider-specific request behavior

### OpenAI-compatible

- Remote configuration required.
- Screenshot multimodal requests use chat-style messages with text plus `image_url`.
- Text-only requests send a plain text message content.
- Request parameters used by the app:
  - `Authorization`
  - `model`
  - `messages`
  - `max_tokens`
- Response fields normalized by the app:
  - `choices[].message.content`
  - `choices[].finish_reason`
  - `usage`
  - `openai-processing-ms`

### Anthropic-compatible

- Remote configuration required.
- Multimodal requests use content blocks with image and text entries.
- Text-only requests send a single text content block.
- Request parameters used by the app:
  - `x-api-key`
  - `anthropic-version`
  - `model`
  - `max_tokens`
  - `messages`
- Response fields normalized by the app:
  - `content[].text`
  - `stop_reason`
  - `usage`
  - `request-id`

### LM Studio

- Remote configuration required.
- Text-only requests send `input` as a plain string.
- Multimodal screenshot requests prefer LM Studio v1 input items with one `"text"` item plus one `"image"` item.
- Some LM Studio builds still validate the multimodal text item as `"message"` instead of `"text"`. The app detects the documented `invalid_union` input error and retries once with the alternate discriminator so both server variants keep working.
- The app passes a configurable `context_length`.
- The app always sets `store: false`, so LM Studio does not persist request history and the app does not continue prior chats with `previous_response_id`.
- Timing diagnostics are surfaced more explicitly than for other providers.
- LM Studio pause and unload diagnostics are also written into `app_logs` with source `lm_studio` so the log window can be used for local debugging.
- Request parameters used by the app:
  - `Authorization`
  - `model`
  - `input`
  - `store`
  - `context_length`
- Response fields normalized by the app:
  - `model_instance_id`
  - `output[].type`
  - `output[].content`
  - `stats`
  - `response_id`

## LM Studio model lifecycle

LM Studio model lifecycle is opt-in per model profile. When the toggle is enabled, the feature service first uses `LMStudioModelLifecycle`; when the toggle is disabled, the app sends chat requests directly and assumes the model is already loaded in LM Studio.

Explicit lifecycle calls:

- Load:
  `POST /api/v1/models/load`
  with `model`, `context_length`, and `echo_load_config: true`.
- Unload:
  `POST /api/v1/models/unload`
  with the loaded model `instance_id`.
- Fallback unload:
  when the app did not capture an `instance_id`, it reads `GET /api/v1/models` and matches a loaded instance by trimmed model name plus `context_length`.
  This is also the path used by the menu-bar force-unload fallback when automatic unload fails or a user explicitly requests a manual unload.

Entry-point behavior:

- Screenshot analysis loads the LM Studio analysis model once before a run and reuses it for all screenshots in that run when lifecycle management is enabled.
- The settings model test path uses `load -> chat -> unload` when the screenshot-analysis profile has lifecycle management enabled.
- Independent daily-summary generation uses `load -> summary chat -> unload` when its profile is LM Studio and lifecycle management is enabled.
- Automatic daily-summary generation after a screenshot-analysis run can reuse, switch, or release the analysis model depending on the two model profiles and whether each profile has lifecycle management enabled.

Automatic analysis-to-summary handoff rules:

- LM Studio analysis plus LM Studio summary with equivalent configuration:
  keep the analysis model loaded and let the summary reuse it when the analysis profile has lifecycle management enabled.
- LM Studio analysis plus LM Studio summary with different configuration:
  unload the analysis model before running the summary, then let the summary profile manage its own lifecycle when enabled.
- LM Studio analysis plus non-LM Studio summary:
  unload the analysis model before running the summary when the analysis profile is managing lifecycle.
- Non-LM Studio analysis plus LM Studio summary:
  let the summary profile load and unload its own model when lifecycle management is enabled.
- Non-LM Studio analysis plus non-LM Studio summary:
  no LM Studio lifecycle calls.

LM Studio configuration equivalence compares:

- normalized chat endpoint from `ModelProvider.lmStudio.requestURL(from:)`
- trimmed model name
- `lmStudioContextLength`

The API key is not part of equivalence. Load, unload, and chat requests still use the API key from their own model profile.

On a user-initiated pause, the app first cancels the active generation request and only starts the unload call after the request has finished cancelling.
The pause state does not return to idle until the unload attempt finishes.

## Configuration model

Each model profile contains:

- provider
- base URL
- model name
- API key
- LM Studio context length
- LM Studio auto load/unload toggle
- image analysis method

Behavior rules:

- Remote providers require base URL and model name.
- Apple Intelligence does not require base URL or API key.
- Apple Intelligence forces screenshot analysis into OCR mode.

## Failure handling

- Screenshot analysis retries selected transient failures up to a bounded attempt count.
- Invalid structured output is treated as a model-response failure, not a silent success.
- Runtime provider errors are surfaced in the error store for UI review.
- Daily summary generation skips days that still have no activity items.

## Apple Intelligence request and response model

Apple Intelligence does not use HTTP in this project.

The app sends:

- prompt text
- `SystemLanguageModel(useCase:)`
- `GenerationOptions.maximumResponseTokens`
- optional `GenerationSchema` for guided generation

The app reads back:

- `Response.content` for plain-text generations
- `GeneratedContent` for guided generation
- `GeneratedContent.jsonString` for debug-friendly structured output capture
- `LanguageModelSession.transcript` when it needs to recover the latest structured response text

## When to update this document

Update this file when any of the following changes:

- a provider is added or removed
- request payload formats change
- OCR vs. multimodal routing changes
- Apple Intelligence capabilities or constraints change
- settings fields or validation rules change
