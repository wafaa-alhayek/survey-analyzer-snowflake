-- =====================================================================
-- 02_ingest.sql : turn PDFs into searchable pages and saved answers
--
-- INGEST(model) finds new PDFs in @DOCS and, for each one:
--   1. reads every page with PARSE_DOCUMENT (LAYOUT mode keeps tables)
--   2. splits each page into chunks (a chunk never crosses a page, so
--      every search hit knows its page number)
--   3. asks the LLM to draft the questions people are most likely to
--      ask about it, with short answers in English and Arabic, which an
--      embedding model can later match without calling the LLM again
--   4. refreshes the Cortex Search index
-- Run once as ACCOUNTADMIN, after 01_setup.sql. The app calls INGEST
-- itself whenever someone uploads a PDF.
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE SURVEY_WH;
USE SCHEMA ASK_REPORTS.CORE;

-- ---------------------------------------------------------------------
-- Saved answers for every document that has none yet.
-- TRY_COMPLETE returns nothing instead of failing, so a model that is
-- not available here never blocks loading: run it again with another
-- model, e.g. CALL DRAFT_SAVED_ANSWERS('llama3.3-70b');
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE DRAFT_SAVED_ANSWERS(MODEL STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  n INTEGER DEFAULT 0;
BEGIN
  INSERT INTO SAVED_ANSWERS (DOC_ID, COLLECTION, QUESTION, QUESTION_AR, ANSWER_EN, ANSWER_AR, PAGES)
  WITH doc_text AS (
    SELECT d.DOC_ID, d.COLLECTION, d.TITLE,
           LEFT(LISTAGG('[Page ' || p.PAGE_NO || ']\n' || p.PAGE_TEXT, '\n\n')
                  WITHIN GROUP (ORDER BY p.PAGE_NO), 40000) AS TXT
    FROM DOCUMENTS d
    JOIN PAGES p ON p.DOC_ID = d.DOC_ID
    WHERE d.STATUS IN ('NEW', 'READY')
      AND NOT EXISTS (SELECT 1 FROM SAVED_ANSWERS s WHERE s.DOC_ID = d.DOC_ID)
    GROUP BY d.DOC_ID, d.COLLECTION, d.TITLE
  ),
  drafted AS (
    SELECT DOC_ID, COLLECTION,
      SNOWFLAKE.CORTEX.TRY_COMPLETE(:MODEL,
        'You prepare a question bank for a document search app used by humanitarian workers and researchers. '
        || 'Read the document below and write the 8 questions a reader is most likely to ask about it, '
        || 'each with a short answer taken only from the document. Rules: '
        || 'Each answer is at most 60 words. Copy every number exactly as written in the document. '
        || 'Write each question in English (question) and in Modern Standard Arabic (question_ar). '
        || 'Give each answer in English (answer_en) and in Modern Standard Arabic (answer_ar). '
        || 'List the page numbers the answer comes from, using the [Page N] markers. '
        || 'Do not ask about people by name. '
        || 'Return only a JSON array, no other text, in this form: '
        || '[{"question": "...", "question_ar": "...", "answer_en": "...", "answer_ar": "...", "pages": [1, 2]}]'
        || '\n\nDocument title: ' || TITLE || '\n\n' || TXT) AS RESP
    FROM doc_text
  )
  SELECT DOC_ID, COLLECTION,
         q.value:question::STRING, q.value:question_ar::STRING, q.value:answer_en::STRING, q.value:answer_ar::STRING,
         q.value:pages::ARRAY
  FROM drafted,
       LATERAL FLATTEN(INPUT => TRY_PARSE_JSON(REGEXP_SUBSTR(RESP, '\\[.*\\]', 1, 1, 's'))) q
  WHERE q.value:question IS NOT NULL AND q.value:answer_en IS NOT NULL;

  n := SQLROWCOUNT;

  -- The embedding model that later does the matching, one embedding per
  -- language so each question is compared with a question in its own language
  UPDATE SAVED_ANSWERS
  SET Q_EMB = SNOWFLAKE.CORTEX.EMBED_TEXT_1024('snowflake-arctic-embed-l-v2.0', QUESTION),
      Q_EMB_AR = SNOWFLAKE.CORTEX.EMBED_TEXT_1024('snowflake-arctic-embed-l-v2.0', COALESCE(QUESTION_AR, QUESTION))
  WHERE Q_EMB IS NULL;

  RETURN 'Saved ' || n || ' drafted answers.';
END;
$$;

-- ---------------------------------------------------------------------
-- Load every new PDF in @DOCS
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE INGEST(MODEL STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  n_new INTEGER DEFAULT 0;
  n_failed INTEGER DEFAULT 0;
  n_pages INTEGER DEFAULT 0;
  drafted STRING DEFAULT '';
BEGIN
  ALTER STAGE ASK_REPORTS.CORE.DOCS REFRESH;

  -- PDFs in a collection folder that are not registered yet
  INSERT INTO DOCUMENTS (DOC_ID, COLLECTION, FILE_NAME, TITLE, STATUS)
  SELECT RELATIVE_PATH,
         UPPER(SPLIT_PART(RELATIVE_PATH, '/', 1)),
         SPLIT_PART(RELATIVE_PATH, '/', -1),
         REPLACE(REPLACE(SPLIT_PART(RELATIVE_PATH, '/', -1), '.pdf', ''), '_', ' '),
         'NEW'
  FROM DIRECTORY(@ASK_REPORTS.CORE.DOCS)
  WHERE LOWER(RELATIVE_PATH) LIKE '%.pdf'
    AND CONTAINS(RELATIVE_PATH, '/')
    AND RELATIVE_PATH NOT IN (SELECT DOC_ID FROM DOCUMENTS);

  SELECT COUNT(*) INTO :n_new FROM DOCUMENTS WHERE STATUS = 'NEW';
  IF (n_new = 0) THEN
    RETURN 'No new documents.';
  END IF;

  -- A re-uploaded file replaces its old pages, chunks and saved answers
  DELETE FROM PAGES         WHERE DOC_ID IN (SELECT DOC_ID FROM DOCUMENTS WHERE STATUS = 'NEW');
  DELETE FROM CHUNKS        WHERE DOC_ID IN (SELECT DOC_ID FROM DOCUMENTS WHERE STATUS = 'NEW');
  DELETE FROM SAVED_ANSWERS WHERE DOC_ID IN (SELECT DOC_ID FROM DOCUMENTS WHERE STATUS = 'NEW');

  -- 1. Read every page
  CREATE OR REPLACE TEMPORARY TABLE PARSED AS
  SELECT DOC_ID,
         SNOWFLAKE.CORTEX.PARSE_DOCUMENT(@ASK_REPORTS.CORE.DOCS, DOC_ID,
           {'mode': 'LAYOUT', 'page_split': TRUE}) AS P
  FROM DOCUMENTS
  WHERE STATUS = 'NEW';

  INSERT INTO PAGES (DOC_ID, PAGE_NO, PAGE_TEXT)
  SELECT r.DOC_ID, pg.value:index::INTEGER + 1, pg.value:content::STRING
  FROM PARSED r, LATERAL FLATTEN(INPUT => r.P:pages) pg
  WHERE LENGTH(TRIM(pg.value:content::STRING)) > 0;

  UPDATE DOCUMENTS d SET PAGE_COUNT = x.N
  FROM (SELECT DOC_ID, COUNT(*) AS N FROM PAGES GROUP BY DOC_ID) x
  WHERE d.DOC_ID = x.DOC_ID AND d.STATUS = 'NEW';

  UPDATE DOCUMENTS d
  SET STATUS = 'FAILED',
      ERROR = LEFT(COALESCE(r.P:errorInformation::STRING, 'No readable text found'), 500)
  FROM PARSED r
  WHERE d.DOC_ID = r.DOC_ID AND d.STATUS = 'NEW' AND COALESCE(d.PAGE_COUNT, 0) = 0;

  -- 2. Chunks of about 1,800 characters with 250 characters of overlap
  INSERT INTO CHUNKS (CHUNK_ID, DOC_ID, COLLECTION, TITLE, PAGE_NO, CHUNK_TEXT)
  SELECT p.DOC_ID || '#p' || p.PAGE_NO || '-' || c.index,
         p.DOC_ID, d.COLLECTION, d.TITLE, p.PAGE_NO, c.value::STRING
  FROM PAGES p
  JOIN DOCUMENTS d ON d.DOC_ID = p.DOC_ID AND d.STATUS = 'NEW',
  LATERAL FLATTEN(INPUT => SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
    p.PAGE_TEXT, 'markdown', 1800, 250)) c
  WHERE LENGTH(TRIM(c.value::STRING)) > 40;

  -- 3. Saved answers
  CALL DRAFT_SAVED_ANSWERS(:MODEL) INTO :drafted;

  SELECT COALESCE(SUM(PAGE_COUNT), 0) INTO :n_pages FROM DOCUMENTS WHERE STATUS = 'NEW';
  SELECT COUNT(*) INTO :n_failed FROM DOCUMENTS WHERE STATUS = 'FAILED';
  UPDATE DOCUMENTS SET STATUS = 'READY' WHERE STATUS = 'NEW';

  -- 4. Rebuild the search index now instead of waiting for TARGET_LAG.
  --    Skipped quietly before 04_search.sql has created the service.
  BEGIN
    ALTER CORTEX SEARCH SERVICE ASK_REPORTS.CORE.REPORTS_SEARCH REFRESH;
  EXCEPTION
    WHEN OTHER THEN NULL;
  END;

  RETURN 'Loaded ' || (n_new - n_failed) || ' documents (' || n_pages || ' pages). '
         || drafted || ' Documents that could not be read: ' || n_failed || '.';
END;
$$;

-- ---------------------------------------------------------------------
-- Remove one document, or a whole collection, everywhere
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE DELETE_DOCUMENT(P_DOC_ID STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
  EXECUTE IMMEDIATE 'REMOVE ''@ASK_REPORTS.CORE.DOCS/' || REPLACE(:P_DOC_ID, '''', '') || '''';
  DELETE FROM SAVED_ANSWERS WHERE DOC_ID = :P_DOC_ID;
  DELETE FROM CHUNKS        WHERE DOC_ID = :P_DOC_ID;
  DELETE FROM PAGES         WHERE DOC_ID = :P_DOC_ID;
  DELETE FROM DOCUMENTS     WHERE DOC_ID = :P_DOC_ID;
  BEGIN
    ALTER CORTEX SEARCH SERVICE ASK_REPORTS.CORE.REPORTS_SEARCH REFRESH;
  EXCEPTION
    WHEN OTHER THEN NULL;
  END;
  RETURN 'Deleted ' || :P_DOC_ID;
END;
$$;

CREATE OR REPLACE PROCEDURE DELETE_COLLECTION(P_COLLECTION STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
  EXECUTE IMMEDIATE 'REMOVE ''@ASK_REPORTS.CORE.DOCS/' || REPLACE(:P_COLLECTION, '''', '') || '/''';
  DELETE FROM SAVED_ANSWERS WHERE COLLECTION = :P_COLLECTION;
  DELETE FROM CHUNKS        WHERE COLLECTION = :P_COLLECTION;
  DELETE FROM PAGES         WHERE DOC_ID IN (SELECT DOC_ID FROM DOCUMENTS WHERE COLLECTION = :P_COLLECTION);
  DELETE FROM DOCUMENTS     WHERE COLLECTION = :P_COLLECTION;
  DELETE FROM COLLECTIONS   WHERE COLLECTION = :P_COLLECTION;
  BEGIN
    ALTER CORTEX SEARCH SERVICE ASK_REPORTS.CORE.REPORTS_SEARCH REFRESH;
  EXCEPTION
    WHEN OTHER THEN NULL;
  END;
  RETURN 'Deleted collection ' || :P_COLLECTION;
END;
$$;

SHOW PROCEDURES IN SCHEMA ASK_REPORTS.CORE;
