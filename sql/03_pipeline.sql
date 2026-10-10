-- =====================================================================
-- 03_pipeline.sql : the analysis procedure
--
--   CALL SURVEY_ANALYZER.CORE.RUN_ANALYSIS('DEMO_NEEDS_2026', 'llama3.1-70b');
--
-- What it does, all inside your Snowflake account:
--   1. Pattern redaction: emails and phone/ID numbers are replaced with
--      [EMAIL] / [PHONE] before any AI model sees the text.
--   2. One Cortex call per response: detects the language, removes names
--      and addresses, translates to English, labels sentiment and picks
--      1-3 short topics. Works for Arabic and English (and most others).
--   3. One Cortex call per survey: groups all topics into 4-8 themes.
--   4. One Cortex call per response: assigns each response to one theme.
--   5. Sentiment score (-1..1) from the model's label (Cortex SENTIMENT as fallback).
-- Re-running for the same survey replaces its previous results.
-- =====================================================================

USE WAREHOUSE SURVEY_WH;
USE SCHEMA SURVEY_ANALYZER.CORE;

CREATE OR REPLACE PROCEDURE RUN_ANALYSIS(P_SURVEY_ID STRING, P_MODEL STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  n_responses INTEGER DEFAULT 0;
  n_themes    INTEGER DEFAULT 0;
  n_failed    INTEGER DEFAULT 0;
BEGIN
  -- Start clean for this survey
  DELETE FROM RESPONSE_THEMES    WHERE SURVEY_ID = :P_SURVEY_ID;
  DELETE FROM THEMES             WHERE SURVEY_ID = :P_SURVEY_ID;
  DELETE FROM RESPONSES_ENRICHED WHERE SURVEY_ID = :P_SURVEY_ID;

  -- Steps 1 + 2: pattern redaction, then one model call per response
  INSERT INTO RESPONSES_ENRICHED
    (RESPONSE_ID, SURVEY_ID, REGION, AGE_GROUP, LANGUAGE, TEXT_REDACTED,
     TEXT_EN, SENTIMENT_LABEL, TOPICS, MODEL)
  SELECT
    RESPONSE_ID, SURVEY_ID, REGION, AGE_GROUP,
    COALESCE(J:language::STRING, 'unknown'),
    -- If the model output cannot be read, keep the pattern-redacted text
    COALESCE(J:redacted::STRING, PRE_REDACTED),
    J:english::STRING,
    LOWER(J:sentiment::STRING),
    IFF(IS_ARRAY(J:topics), J:topics::ARRAY, ARRAY_CONSTRUCT()),
    :P_MODEL
  FROM (
    SELECT L.*,
           TRY_PARSE_JSON(REGEXP_SUBSTR(L.LLM_OUT, '\\{.*\\}', 1, 1, 's')) AS J
    FROM (
      SELECT R.*,
        SNOWFLAKE.CORTEX.COMPLETE(
          :P_MODEL,
          'You analyze survey responses for a humanitarian research team. '
          || 'Return ONLY one JSON object and no other text, with these keys: '
          || '"language": ISO 639-1 code of the response such as "ar" or "en"; '
          || '"redacted": the response in its ORIGINAL language, unchanged except that every '
          || 'personal name is replaced by [NAME], every exact address or home location by [ADDRESS], '
          || 'every phone number by [PHONE], every email by [EMAIL] and every ID number by [ID]; '
          || '"english": an English translation of the redacted text; '
          || '"sentiment": one of "positive", "neutral", "negative", "mixed"; '
          || '"topics": an array of 1 to 3 short English topic phrases of 2 to 4 words each. '
          || 'Survey question: ' || COALESCE(R.QUESTION, 'not provided')
          || ' Response: <<<' || R.PRE_REDACTED || '>>>'
        ) AS LLM_OUT
      FROM (
        SELECT RESPONSE_ID, SURVEY_ID, REGION, AGE_GROUP, QUESTION,
          REGEXP_REPLACE(
            REGEXP_REPLACE(RESPONSE_TEXT,
              '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}', '[EMAIL]'),
            '\\+?[0-9٠-٩][0-9٠-٩ ()-]{6,}[0-9٠-٩]', '[PHONE]') AS PRE_REDACTED
        FROM RESPONSES_RAW
        WHERE SURVEY_ID = :P_SURVEY_ID
      ) R
    ) L
  );

  -- Step 5 (run early so the theme step can be retried alone if needed):
  -- numeric sentiment on the English text
  -- The model's own label is used first: Cortex SENTIMENT reads translated
  -- text as close to neutral, so it is only a fallback when no label exists.
  UPDATE RESPONSES_ENRICHED
     SET SENTIMENT_SCORE = CASE SENTIMENT_LABEL
           WHEN 'positive' THEN 1
           WHEN 'negative' THEN -1
           WHEN 'neutral'  THEN 0
           WHEN 'mixed'    THEN 0
           ELSE SNOWFLAKE.CORTEX.SENTIMENT(COALESCE(TEXT_EN, TEXT_REDACTED))
         END
   WHERE SURVEY_ID = :P_SURVEY_ID;

  -- Step 3: discover themes from all topic phrases in this survey
  INSERT INTO THEMES (SURVEY_ID, THEME, DESCRIPTION)
  SELECT :P_SURVEY_ID, TRIM(F.VALUE:theme::STRING), F.VALUE:description::STRING
  FROM (
    SELECT TRY_PARSE_JSON(REGEXP_SUBSTR(MODEL_OUT, '\\[.*\\]', 1, 1, 's')) AS ARR
    FROM (
      SELECT SNOWFLAKE.CORTEX.COMPLETE(
        :P_MODEL,
        'Below are short topic phrases taken from answers to one survey. '
        || 'Group them into between 4 and 8 broad, non-overlapping themes that a humanitarian '
        || 'programme team could act on. Return ONLY a JSON array, no other text. Each item is an '
        || 'object with keys "theme" (2 to 4 words, Title Case) and "description" (one sentence). '
        || 'Topic phrases: ' || TOPIC_LIST
      ) AS MODEL_OUT
      FROM (
        SELECT LISTAGG(DISTINCT LOWER(T.VALUE::STRING), '; ') AS TOPIC_LIST
        FROM RESPONSES_ENRICHED E, LATERAL FLATTEN(INPUT => E.TOPICS) T
        WHERE E.SURVEY_ID = :P_SURVEY_ID
      ) TL
      WHERE TL.TOPIC_LIST IS NOT NULL
    ) O
  ) P, LATERAL FLATTEN(INPUT => P.ARR) F
  WHERE F.VALUE:theme IS NOT NULL;

  -- Step 4: assign each response to one theme
  INSERT INTO RESPONSE_THEMES (RESPONSE_ID, SURVEY_ID, THEME)
  SELECT A.RESPONSE_ID, :P_SURVEY_ID, COALESCE(T.THEME, 'Other')
  FROM (
    SELECT E.RESPONSE_ID,
      SNOWFLAKE.CORTEX.COMPLETE(
        :P_MODEL,
        'Choose the single theme that best fits the survey response. '
        || 'Answer with the theme name exactly as written and nothing else. '
        || 'Themes: ' || TL.THEME_LIST
        || '. Response: <<<' || COALESCE(E.TEXT_EN, E.TEXT_REDACTED) || '>>>'
      ) AS ANSWER
    FROM RESPONSES_ENRICHED E
    CROSS JOIN (
      SELECT LISTAGG(THEME, ' | ') AS THEME_LIST FROM THEMES WHERE SURVEY_ID = :P_SURVEY_ID
    ) TL
    WHERE E.SURVEY_ID = :P_SURVEY_ID
      AND TL.THEME_LIST IS NOT NULL
  ) A
  LEFT JOIN THEMES T
    ON T.SURVEY_ID = :P_SURVEY_ID
   AND CONTAINS(LOWER(A.ANSWER), LOWER(T.THEME))
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY A.RESPONSE_ID
    ORDER BY POSITION(LOWER(T.THEME) IN LOWER(A.ANSWER)) NULLS LAST
  ) = 1;

  SELECT COUNT(*), COUNT_IF(TEXT_EN IS NULL)
    INTO :n_responses, :n_failed
    FROM RESPONSES_ENRICHED WHERE SURVEY_ID = :P_SURVEY_ID;
  SELECT COUNT(*) INTO :n_themes FROM THEMES WHERE SURVEY_ID = :P_SURVEY_ID;

  RETURN 'Analyzed ' || n_responses || ' responses into ' || n_themes
         || ' themes with ' || P_MODEL || '. Responses the model could not read: '
         || n_failed || '.';
END;
$$;

-- Run it on the sample survey (about 1-3 minutes on an XS warehouse)
CALL RUN_ANALYSIS('DEMO_NEEDS_2026', 'llama3.1-70b');

-- Inspect the results
SELECT * FROM THEMES WHERE SURVEY_ID = 'DEMO_NEEDS_2026';
SELECT E.LANGUAGE, E.TEXT_REDACTED, E.TEXT_EN, E.SENTIMENT_LABEL, E.SENTIMENT_SCORE, T.THEME
FROM RESPONSES_ENRICHED E
JOIN RESPONSE_THEMES T ON T.RESPONSE_ID = E.RESPONSE_ID AND T.SURVEY_ID = E.SURVEY_ID
WHERE E.SURVEY_ID = 'DEMO_NEEDS_2026'
ORDER BY T.THEME;
