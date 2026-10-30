-- =====================================================================
-- Ask your reports on Snowflake Cortex
-- 01_setup.sql : database, PDF stage, tables
--
-- Clients upload PDFs and ask questions in Arabic or English. Each
-- answer cites the document and page it came from.
-- Reuses the Survey Analyzer's SURVEY_WH warehouse, its client list
-- (SURVEY_ANALYZER.CORE.CLIENTS, APP_ADMINS) and the SURVEY_CLIENT role,
-- so run the Survey Analyzer files 01 and 06 first.
-- Run as ACCOUNTADMIN. Trial accounts: public documents only.
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE SURVEY_WH;

CREATE DATABASE IF NOT EXISTS ASK_REPORTS;
CREATE SCHEMA IF NOT EXISTS ASK_REPORTS.CORE;
USE SCHEMA ASK_REPORTS.CORE;

-- ---------------------------------------------------------------------
-- 1. Where the PDFs live. Each collection is a folder:
--    @DOCS/GAZA_REPORTS/file.pdf, @DOCS/<CLIENT_COLLECTION>/file.pdf
--    PARSE_DOCUMENT needs server-side encryption and a directory table.
-- ---------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS DOCS
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Uploaded PDFs, one folder per collection';

-- ---------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------

-- A collection is a set of documents searched together.
-- CLIENT_ID NULL = public demo collection, visible to every login.
CREATE TABLE IF NOT EXISTS COLLECTIONS (
  COLLECTION   STRING NOT NULL,     -- folder name in @DOCS, capitals
  TITLE        STRING,
  CLIENT_ID    STRING,
  CREATED_AT   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS DOCUMENTS (
  DOC_ID         STRING NOT NULL,   -- = path inside the stage
  COLLECTION     STRING NOT NULL,
  FILE_NAME      STRING,
  TITLE          STRING,
  SOURCE_URL     STRING,            -- public link, if any
  PAGE_COUNT     INTEGER,
  STATUS         STRING,            -- NEW, READY, FAILED
  ERROR          STRING,
  UPLOADED_BY    STRING,
  LOADED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Text of each page, as read by PARSE_DOCUMENT (LAYOUT mode keeps tables)
CREATE TABLE IF NOT EXISTS PAGES (
  DOC_ID     STRING NOT NULL,
  PAGE_NO    INTEGER NOT NULL,      -- 1 = first page
  PAGE_TEXT  STRING
);

-- Searchable pieces of each page. Chunks never cross a page boundary,
-- so every search hit knows its exact page.
CREATE TABLE IF NOT EXISTS CHUNKS (
  CHUNK_ID    STRING NOT NULL,
  DOC_ID      STRING NOT NULL,
  COLLECTION  STRING NOT NULL,
  TITLE       STRING,
  PAGE_NO     INTEGER,
  CHUNK_TEXT  STRING
);

-- Saved answers: when a document is loaded, the LLM drafts the questions
-- people are most likely to ask, with answers in English and Arabic.
-- At question time a cheap embedding model matches the user's question
-- against these, in the same language (tested on this account: a
-- reworded question scores 0.89 to 0.95, a different question 0.71 to
-- 0.75, but across languages the scores overlap, so both are stored). A close match is answered instantly, without the LLM.
CREATE TABLE IF NOT EXISTS SAVED_ANSWERS (
  DOC_ID      STRING NOT NULL,
  COLLECTION  STRING NOT NULL,
  QUESTION    STRING,              -- English
  QUESTION_AR STRING,              -- the same question in Arabic
  ANSWER_EN   STRING,
  ANSWER_AR   STRING,
  PAGES       ARRAY,
  Q_EMB       VECTOR(FLOAT, 1024), -- embedding of QUESTION
  Q_EMB_AR    VECTOR(FLOAT, 1024), -- embedding of QUESTION_AR
  CREATED_AT  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- What was asked, for improving the app. Deleted after 30 days.
CREATE TABLE IF NOT EXISTS QUESTION_LOG (
  ASKED_AT     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  SNOWFLAKE_USER STRING,
  COLLECTION   STRING,
  QUESTION     STRING,
  ANSWERED_BY  STRING,              -- SAVED or the LLM model name
  SECONDS      FLOAT
);

-- ---------------------------------------------------------------------
-- 3. The two demo collections
-- ---------------------------------------------------------------------
MERGE INTO COLLECTIONS t
USING (
  SELECT 'GAZA_REPORTS' AS COLLECTION, 'Gaza humanitarian reports (OCHA, UNRWA, UN Women)' AS TITLE
  UNION ALL
  SELECT 'GAZA_HEALTH_PAPERS', 'Gaza health research (open-access papers)'
) s
ON t.COLLECTION = s.COLLECTION
WHEN NOT MATCHED THEN INSERT (COLLECTION, TITLE, CLIENT_ID) VALUES (s.COLLECTION, s.TITLE, NULL);

SHOW TABLES IN SCHEMA ASK_REPORTS.CORE;
