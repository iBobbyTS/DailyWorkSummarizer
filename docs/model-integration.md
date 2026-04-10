# Model Integration

## Model surfaces in the app

The app uses model integration in two places:

- Screenshot analysis
  Categorize a screenshot and generate a short item summary.
- Daily report summarization
  Generate a daily summary and per-category summaries from structured activity text.

These two features use separate settings and may use different providers.

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

Important constraint:

- The current implementation does not send screenshot image bytes directly into `FoundationModels`.
- In practice, Apple Intelligence should be treated as an OCR-first local analysis option in this project.

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
- Multimodal screenshot requests send `input` as LM Studio v1 input items with one `"message"` item plus one `"image"` item.
- The app passes a configurable `context_length`.
- The app always sets `store: false`, so LM Studio does not persist request history and the app does not continue prior chats with `previous_response_id`.
- Timing diagnostics are surfaced more explicitly than for other providers.
- Request parameters used by the app:
  - `Authorization`
  - `model`
  - `input`
  - `store`
  - `context_length`
- Response fields normalized by the app:
  - `output[].type`
  - `output[].content`
  - `stats`
  - `response_id`

## Configuration model

Each model profile contains:

- provider
- base URL
- model name
- API key
- LM Studio context length
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
