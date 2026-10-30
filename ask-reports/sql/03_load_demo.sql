-- =====================================================================
-- 03_load_demo.sql : load the two public demo collections from GitHub
--
-- Copies the 10 demo PDFs (96 pages) from the GitHub repo into @DOCS,
-- gives them proper titles and links, then reads them with INGEST.
-- Uses SURVEY_ANALYZER.CORE.APP_REPO, created by the Survey Analyzer's
-- sql/07_publish_app.sql. Takes a few minutes. Run once as ACCOUNTADMIN.
-- Expected cost: well under 1 credit (PARSE_DOCUMENT + saved answers).
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE SURVEY_WH;
USE SCHEMA ASK_REPORTS.CORE;

-- Get the latest files from GitHub
ALTER GIT REPOSITORY SURVEY_ANALYZER.CORE.APP_REPO FETCH;

COPY FILES INTO @ASK_REPORTS.CORE.DOCS/GAZA_REPORTS/
  FROM @SURVEY_ANALYZER.CORE.APP_REPO/branches/main/ask-reports/demo/gaza_reports/
  PATTERN = '.*[.]pdf';

COPY FILES INTO @ASK_REPORTS.CORE.DOCS/GAZA_HEALTH_PAPERS/
  FROM @SURVEY_ANALYZER.CORE.APP_REPO/branches/main/ask-reports/demo/gaza_health_papers/
  PATTERN = '.*[.]pdf';

ALTER STAGE ASK_REPORTS.CORE.DOCS REFRESH;

-- Titles and public links, so answers cite "OCHA report, 22 Oct 2026, page 3"
-- instead of a file name. See ask-reports/demo/SOURCES.md.
MERGE INTO DOCUMENTS t
USING (
  SELECT column1 AS DOC_ID, column2 AS TITLE, column3 AS SOURCE_URL FROM VALUES
  ('GAZA_REPORTS/ocha_sitrep_2026-10-22.pdf', 'OCHA Humanitarian Situation Report, 22 October 2026', 'https://reliefweb.int/attachments/7c28e9ad-db5e-4434-aed7-8868e97fd7ac/'),
  ('GAZA_REPORTS/ocha_sitrep_2026-10-15.pdf', 'OCHA Humanitarian Situation Report, 15 October 2026', 'https://reliefweb.int/attachments/0872ef74-5d46-4aa4-8af2-736b3e9fbb2a/'),
  ('GAZA_REPORTS/ocha_sitrep_2026-10-02.pdf', 'OCHA Humanitarian Situation Report, 2 October 2026', 'https://reliefweb.int/attachments/afadda55-d3fe-4851-83c7-6ba6ec610987/'),
  ('GAZA_REPORTS/unrwa_sitrep_237.pdf', 'UNRWA Situation Report #237, 7 to 20 October 2026', 'https://reliefweb.int/attachments/dab9d149-4552-4f81-b56d-902b200c0a06/'),
  ('GAZA_REPORTS/gaza_2026_factsheet_ar.pdf', 'UN Women factsheet: women and girls killed or injured in Gaza (Arabic)', 'https://reliefweb.int/attachments/58a0f75b-b5f4-4287-944f-a3796b86f06d/'),
  ('GAZA_HEALTH_PAPERS/plos_midwives_births_in_shelters.pdf', 'Birth in shelters: midwives'' childbirth care amidst war in Gaza (PLOS ONE, 2026)', 'https://doi.org/10.1371/journal.pone.0339551'),
  ('GAZA_HEALTH_PAPERS/plosmh_home_destruction_ptsd.pdf', 'Home destruction, anxiety and PTSD among hemodialysis patients in Gaza (PLOS Mental Health, 2026)', 'https://doi.org/10.1371/journal.pmen.0000682'),
  ('GAZA_HEALTH_PAPERS/frontpubh_war_health_impacts.pdf', 'Beyond the battlefield: war-related health impacts in the Gaza Strip (Frontiers in Public Health, 2026)', 'https://doi.org/10.3389/fpubh.2026.1739474'),
  ('GAZA_HEALTH_PAPERS/frontpubh_children_rights.pdf', 'The failure to protect the rights and needs of children in Gaza (Frontiers in Public Health, 2026)', 'https://doi.org/10.3389/fpubh.2025.1708975'),
  ('GAZA_HEALTH_PAPERS/frontped_child_cancer_rehab.pdf', 'Rehabilitation for children with cancer in Gaza (Frontiers in Pediatrics, 2026)', 'https://doi.org/10.3389/fped.2026.1844813')
) s
ON t.DOC_ID = s.DOC_ID
WHEN MATCHED THEN UPDATE SET TITLE = s.TITLE, SOURCE_URL = s.SOURCE_URL
WHEN NOT MATCHED THEN INSERT (DOC_ID, COLLECTION, FILE_NAME, TITLE, SOURCE_URL, STATUS, UPLOADED_BY)
  VALUES (s.DOC_ID, SPLIT_PART(s.DOC_ID, '/', 1), SPLIT_PART(s.DOC_ID, '/', -1), s.TITLE, s.SOURCE_URL, 'NEW', 'DEMO');

-- Read the PDFs and draft saved answers with Claude (best Arabic; checked
-- available on this account on 30 Oct 2026). If the result says
-- "Saved 0 drafted answers", run:  CALL DRAFT_SAVED_ANSWERS('llama3.3-70b');
CALL INGEST('claude-sonnet-4-5');

-- Check: one row per document, all READY, with pages and saved answers
SELECT d.COLLECTION, d.TITLE, d.STATUS, d.PAGE_COUNT,
       (SELECT COUNT(*) FROM CHUNKS c WHERE c.DOC_ID = d.DOC_ID) AS CHUNKS,
       (SELECT COUNT(*) FROM SAVED_ANSWERS s WHERE s.DOC_ID = d.DOC_ID) AS SAVED_ANSWERS,
       d.ERROR
FROM DOCUMENTS d
ORDER BY d.COLLECTION, d.TITLE;
