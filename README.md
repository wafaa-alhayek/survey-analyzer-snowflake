# Survey Analyzer on Snowflake Cortex

A privacy-first prototype that turns open-text survey answers and reviews, in Arabic or English, into themes and sentiment without the text ever leaving your Snowflake account.

Built for research and humanitarian teams that cannot send respondents' words to an outside AI service.

## What it does

1. **Removes personal details.** Emails and phone/ID numbers are stripped by pattern matching before any model sees the text. A model then replaces names and addresses with `[NAME]`, `[ADDRESS]` and so on.
2. **Understands Arabic and English.** Each response is language-tagged and translated to English for analysis, while the redacted original is kept.
3. **Finds themes.** Topics from every response are grouped into 4 to 8 actionable themes, and each response is assigned to one.
4. **Scores sentiment.** A label (positive, neutral, negative, mixed) and a score from -1 to 1.
5. **Reports only on groups.** Every chart and table hides groups with fewer than 5 responses.
6. **Deletes cleanly.** Raw responses sit in a table with no backup copies, and one click deletes a survey.

## Why the data stays private

- The AI models (Llama, Mistral) run on **Snowflake Cortex inside your Snowflake account and region**. No call goes to OpenAI, Google or Anthropic, and Snowflake does not train on your data.
- The app reads only the reporting views, which never show raw text or small groups.
- Cross-region inference is left **off**, so text is not processed outside your account's region.

## Files

| File | Purpose |
|---|---|
| `sql/01_setup.sql` | XS warehouse with 60s auto-suspend, credit cap, database, tables |
| `sql/02_sample_data.sql` | 40 synthetic responses (20 Arabic, 20 English), no real people |
| `sql/03_pipeline.sql` | `RUN_ANALYSIS` procedure: redact, translate, sentiment, themes |
| `sql/04_report_views.sql` | Group-only reporting views and `DELETE_SURVEY` procedure |
| `sql/06_clients.sql` | Client logins, consent, automatic deletion for pilots |
| `sql/05_fixes.sql` | One-off fixes for installs made before 2026-10-09 (theme %, sentiment score) |
| `streamlit/streamlit_app.py` | Streamlit in Snowflake screen: results, CSV upload, delete |
| `data/sample_responses.csv` | Same synthetic data as a CSV, for testing the upload |
| `docs/SETUP.md` | Step-by-step setup in Snowsight |
| `docs/CONNECT_CLAUDE.md` | Connect Claude to the summary views (read-only) |
| `docs/PILOT_CLIENTS.md` | Give a pilot client their own link |
| `docs/CONNECT_GITHUB.md` | Sync this repo into a Snowflake Workspace |

## Quick start

Follow [docs/SETUP.md](docs/SETUP.md). In short: run the four SQL files in order in a Snowsight worksheet, then paste the Streamlit file into a new Streamlit app.

## Limits of this prototype

- Model-based redaction is good but not perfect. Review a sample of redacted text before sharing anything, and do not collect names in the first place where you can.
- Themes are generated per run, so wording can change slightly between runs.
- Sentiment scores come from an English model applied to the translation.

## Next steps

- Add Snowflake's `AI_REDACT` function for redaction where it is available in your region.
- Schedule `RUN_ANALYSIS` with a Snowflake Task for surveys that collect continuously.
- A self-hosted version on Google Cloud for teams that cannot use any cloud data platform.

## Also in this repo: Ask your reports

[ask-reports/](ask-reports/README.md) lets clients upload PDFs and ask questions
in Arabic or English, with every answer citing its page. It reuses this
project's warehouse, client logins and GitHub connection.
