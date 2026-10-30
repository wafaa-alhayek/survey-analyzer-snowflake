-- =====================================================================
-- 04_search.sql : the Cortex Search service, and putting it to sleep
--
-- Cortex Search finds the page chunks closest in meaning to a question.
-- Its multilingual embedding model lets an Arabic question find English
-- text and the other way round.
--
-- Costs: building the index runs on SURVEY_WH (seconds for the demo),
-- embeddings are billed per token (tiny), and serving is billed for the
-- size of the index for every hour it is awake. A nightly task puts
-- serving to sleep; the app wakes it when someone asks a question.
-- Run once as ACCOUNTADMIN, after 03_load_demo.sql.
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE SURVEY_WH;
USE SCHEMA ASK_REPORTS.CORE;

CREATE OR REPLACE CORTEX SEARCH SERVICE REPORTS_SEARCH
  ON SEARCH_TEXT
  ATTRIBUTES COLLECTION
  WAREHOUSE = SURVEY_WH
  TARGET_LAG = '1 day'
  EMBEDDING_MODEL = 'snowflake-arctic-embed-l-v2.0'
  COMMENT = 'Ask your reports: page chunks of every loaded PDF'
AS
  SELECT TITLE || ' (page ' || PAGE_NO || '): ' || CHUNK_TEXT AS SEARCH_TEXT,
         CHUNK_TEXT, COLLECTION, TITLE, DOC_ID, PAGE_NO, CHUNK_ID
  FROM CHUNKS;

-- ---------------------------------------------------------------------
-- Wake and sleep. The app (which runs as its owner) calls WAKE_SEARCH
-- when a question finds the service asleep.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE WAKE_SEARCH()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
  ALTER CORTEX SEARCH SERVICE ASK_REPORTS.CORE.REPORTS_SEARCH RESUME SERVING;
  ALTER CORTEX SEARCH SERVICE ASK_REPORTS.CORE.REPORTS_SEARCH RESUME INDEXING;
  RETURN 'Search is awake.';
END;
$$;

CREATE OR REPLACE PROCEDURE SLEEP_SEARCH()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
  ALTER CORTEX SEARCH SERVICE ASK_REPORTS.CORE.REPORTS_SEARCH SUSPEND SERVING;
  ALTER CORTEX SEARCH SERVICE ASK_REPORTS.CORE.REPORTS_SEARCH SUSPEND INDEXING;
  -- Questions are kept 30 days, then deleted
  DELETE FROM ASK_REPORTS.CORE.QUESTION_LOG
  WHERE ASKED_AT < DATEADD(day, -30, CURRENT_TIMESTAMP());
  RETURN 'Search is asleep.';
END;
$$;

-- Every night at 21:00 UTC (midnight in Gaza)
CREATE OR REPLACE TASK SLEEP_SEARCH_NIGHTLY
  WAREHOUSE = SURVEY_WH
  SCHEDULE = 'USING CRON 0 21 * * * UTC'
AS
  CALL SLEEP_SEARCH();

ALTER TASK SLEEP_SEARCH_NIGHTLY RESUME;

-- ---------------------------------------------------------------------
-- Test: an Arabic question against the English health papers.
-- Expect 3 rows of results with titles and page numbers.
-- ---------------------------------------------------------------------
SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
  'ASK_REPORTS.CORE.REPORTS_SEARCH',
  '{"query": "ما هي التحديات التي تواجه القابلات أثناء الولادة في الملاجئ؟",
    "columns": ["TITLE", "PAGE_NO", "CHUNK_TEXT"],
    "filter": {"@eq": {"COLLECTION": "GAZA_HEALTH_PAPERS"}},
    "limit": 3}'
)):results AS RESULTS;

DESCRIBE CORTEX SEARCH SERVICE REPORTS_SEARCH;
