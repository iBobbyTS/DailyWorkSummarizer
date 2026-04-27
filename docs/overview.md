# Overview

## Purpose

DeskBrief is a native macOS menu bar app that takes periodic screenshots, classifies work activity, and generates time-based reports and daily summaries.

The app is designed for personal activity review rather than team-wide monitoring. Its core value is turning passive screenshot capture into structured work history that can be browsed as charts and summarized as natural-language reports.

## Primary workflow

1. The app runs as a menu bar utility.
2. It takes screenshots on a fixed interval.
3. It detects idle or away periods and skips unchanged screenshot captures without saving a screenshot.
4. It analyzes screenshots into categories and short summaries on demand, on a schedule, or shortly after a successful capture depending on the selected analysis startup mode. All analysis triggers scan pending screenshots.
5. It aggregates analyzed items into day, week, month, and year reports.
6. It can generate or backfill daily natural-language summaries from analyzed activity.

## Key product areas

- Screenshot
  Periodic screenshots of the active display, plus preview and model-test screenshots.
- Analysis
  Category classification and summary generation using remote providers or Apple Intelligence.
- Reports
  Bar-chart and heatmap views across multiple time ranges, with daily summary details.
- Settings
  Configuration for capture timing, analysis startup mode, language, category rules, and two separate model profiles.
- Errors
  Runtime analysis failures surfaced in a dedicated error view.

## Platform assumptions

- macOS only.
- The app relies on screen recording permission for screenshot capture.
- Apple Intelligence features depend on device eligibility, system settings, and locale support.
- Local persistence is file-based and SQLite-based; there is no backend service.

## Current non-goals

- No cloud sync.
- No multi-user or team features.
- No web client.
- No background daemon outside the app process.
- No generic plugin system for providers or report renderers.

## Important behavior boundaries

- Screenshot analysis and daily report summarization use separate model configurations.
- Remote screenshot analysis can run in either OCR-first or multimodal mode.
- Apple Intelligence currently participates through text-based flows, not direct screenshot-image understanding.
- Daily summaries are generated from stored activity items, not from screenshots directly.
- Away or inactive intervals are not persisted; report views render bounded gaps between analyzed records as display-only `离开` blocks.
