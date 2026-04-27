# Documentation Guide

This repository keeps documentation intentionally lightweight.
The goal is to help a maintainer understand the product, architecture, model integration choices, and local data layout without reading every Swift file first.

## Document set

- `overview.md`
  Product purpose, user-facing workflow, platform assumptions, and non-goals.
- `architecture.md`
  Runtime composition, module responsibilities, and the main data flows.
- `model-integration.md`
  Provider behavior, OCR vs. multimodal paths, and Apple Intelligence constraints.
- `data-and-testing.md`
  Local storage layout, persistence details, recommended test commands, and debugging shortcuts.
- `ui-design.md`
  UI structure, spacing, control alignment, localization, and verification conventions.
- `glossary.md`
  Common Simplified Chinese and English product terms for UI, prompts, docs, and tests.

## Scope and depth

- Prefer concise, high-signal documents.
- Each document should be readable in one short sitting.
- Document decisions and behavior boundaries, not every implementation detail.
- Link code concepts to module names and file names when that improves navigation.

## Maintenance rules

- Update docs together with product or architecture changes that affect user-visible behavior, persistence, configuration, or operational workflows.
- If a change affects model-provider behavior, update `model-integration.md` in the same batch.
- If a change affects schema, storage paths, or runtime debugging steps, update `data-and-testing.md` in the same batch.
- If a change affects module responsibilities or runtime flows, update `architecture.md` in the same batch.
- If a change affects UI layout, visible copy, settings structure, or menu behavior, update `ui-design.md` in the same batch.
- Keep examples and commands aligned with the current project structure and preferred tooling.

## Writing conventions

- Use English for all documentation in `docs/`.
- Prefer short sections and flat lists over long narratives.
- Use exact file or type names where accuracy matters.
- Avoid copying large code blocks into docs unless the code itself is the subject of the explanation.
