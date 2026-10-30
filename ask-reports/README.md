# Ask your reports

Clients upload PDFs and ask questions in Arabic or English. Each answer
cites the document and page it came from, with a link that opens the PDF
on that page. Everything runs inside one Snowflake account.

One engine, demoed on two public collections:

- **Gaza humanitarian reports**: OCHA and UNRWA situation reports and an Arabic UN Women factsheet (5 PDFs, 31 pages)
- **Gaza health research**: open-access (CC BY) papers from PLOS and Frontiers (5 PDFs, 65 pages)

Sources and licences: [demo/SOURCES.md](demo/SOURCES.md). Public documents only; no patient data.

## How it works

```
PDF ──PARSE_DOCUMENT──> pages ──split──> chunks ──Cortex Search──┐
 │                                                               │
 └──LLM drafts 8 likely questions + answers (EN/AR) per PDF      │
                     │                                           │
question ──same-language match ≥ 0.86? ──yes──> saved answer (no LLM)
                     │ no                                        │
                     └──> top 6 chunks from search <─────────────┘
                              └──> LLM answer with [n] page citations
```

1. **Read**: `PARSE_DOCUMENT` in LAYOUT mode reads each page and keeps tables.
2. **Chunk**: pages are split into pieces of about 1,800 characters. A chunk never crosses a page, so every hit knows its page.
3. **Saved answers**: when a PDF is loaded, the LLM drafts the 8 questions people are most likely to ask, in English and Arabic, with short answers in both and their pages. An embedding model compares a new question with the saved questions in the same language. A close match (0.86 or more) is answered instantly and costs almost nothing. On this account a reworded question scored 0.89 to 0.95 and a different question 0.71 to 0.75; across languages the scores overlap, which is why both languages are stored.
4. **Search**: Cortex Search (`snowflake-arctic-embed-l-v2.0`, multilingual) finds the 6 closest chunks in the chosen collection. An Arabic question finds English text and the other way round.
5. **Answer**: the LLM answers only from those chunks, in the question's language, ending each fact with its source number. If the chunks don't hold the answer, it says so.

## Set up (run in order, as ACCOUNTADMIN, in a My Workspace SQL file)

Needs the Survey Analyzer's `SURVEY_WH`, client tables and `APP_REPO`
(its `sql/01_setup.sql`, `06_clients.sql`, `07_publish_app.sql`) first.

| File | What it does | Time |
|---|---|---|
| `sql/00_claude_builder.sql` | Optional: lets Claude run and fix files 01 to 05 itself, inside `ASK_REPORTS` only | seconds |
| `sql/01_setup.sql` | Database `ASK_REPORTS`, PDF stage, tables, the two demo collections | seconds |
| `sql/02_ingest.sql` | Procedures `INGEST`, `DRAFT_SAVED_ANSWERS`, `DELETE_DOCUMENT`, `DELETE_COLLECTION` | seconds |
| `sql/03_load_demo.sql` | Copies the 10 demo PDFs from GitHub and reads them | a few minutes |
| `sql/04_search.sql` | Cortex Search service, wake and sleep procedures, nightly sleep task, a test search | 1 to 3 minutes |
| `sql/05_publish_app.sql` | The app `ASK_REPORTS.CORE.ASK_APP` on `SURVEY_WH`, opened by role `SURVEY_CLIENT` | seconds |
| `sql/06_check_spend.sql` | Credits used, by service and by day | any time |

The pilot client logins from the Survey Analyzer can open this app too.
Each client sees the two demo collections plus their own private
collection, and only they and the admins can add or delete files in it.

## Cost (trial credit)

Rough figures from Snowflake's published Cortex rates; check the real
numbers with `sql/06_check_spend.sql`.

| Item | When | Estimate |
|---|---|---|
| Reading the demo PDFs (96 pages) | once | about 0.3 credits |
| Drafting saved answers (10 PDFs) | once | under 0.5 credits |
| One question answered by the LLM | per question | about 0.005 to 0.02 credits |
| One question answered from a saved answer | per question | close to 0 |
| Search serving (index of a few MB) | while awake | under 0.1 credits a month |
| `SURVEY_WH` while the app is open | per hour of use | up to 1 credit an hour |

The warehouse is the biggest cost: it stays on while someone has the app
open, and stops a minute after they leave. At about $3 a credit, the
$30 to $70 budget covers roughly 10 to 20 hours of demos plus everything
else above. Search goes to sleep every night at 21:00 UTC and wakes when
someone asks a question (the first answer then takes about a minute).

## Models

Checked on this account (AWS us-east-2) on 30 Oct 2026: `claude-sonnet-4-5`,
`llama3.3-70b` and `llama3.1-70b` answer; `mistral-large2` does not. The app
uses Claude and falls back to `llama3.3-70b`.

## What was tested

Tested on the live account through the read-only connector: the models
above, the multilingual embedding scores, chunking, and the saved-answer
prompt (Claude returned valid JSON with Arabic questions, answers and page
numbers). Not yet tested: the stage, PARSE_DOCUMENT on the demo PDFs, the
search service and the app itself. Expect a fix or two on the first run.
The checks at the end of files 03 and 04 show whether each step worked.
