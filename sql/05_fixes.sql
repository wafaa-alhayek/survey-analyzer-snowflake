-- Two fixes. Paste everything into one worksheet and Run All.
-- 1. Theme percentages were calculated only over the themes shown,
--    so they added up to 100% even though small themes were hidden.
-- 2. Sentiment scores read as nearly neutral even when 85% of answers
--    were negative. The score now follows the AI's own label.
-- Paste into a Snowsight worksheet and Run All. COPY GRANTS keeps Claude's access.
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE SURVEY_WH;
USE SCHEMA SURVEY_ANALYZER.CORE;

-- Themes with share of responses and sentiment.
-- The share is computed over ALL responses before small themes are hidden.
CREATE OR REPLACE VIEW V_THEME_SUMMARY COPY GRANTS AS
WITH ALL_THEMES AS (
  SELECT
    RT.SURVEY_ID,
    RT.THEME,
    ANY_VALUE(TH.DESCRIPTION)                                            AS DESCRIPTION,
    COUNT(*)                                                             AS RESPONSES,
    ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY RT.SURVEY_ID), 1) AS PCT_OF_SURVEY,
    ROUND(AVG(E.SENTIMENT_SCORE), 2)                                     AS AVG_SENTIMENT,
    ROUND(100 * COUNT_IF(E.SENTIMENT_LABEL = 'negative') / COUNT(*), 0)  AS PCT_NEGATIVE,
    COUNT_IF(E.LANGUAGE = 'ar')                                          AS ARABIC,
    COUNT_IF(E.LANGUAGE = 'en')                                          AS ENGLISH
  FROM RESPONSE_THEMES RT
  JOIN RESPONSES_ENRICHED E
    ON E.RESPONSE_ID = RT.RESPONSE_ID AND E.SURVEY_ID = RT.SURVEY_ID
  LEFT JOIN THEMES TH
    ON TH.SURVEY_ID = RT.SURVEY_ID AND TH.THEME = RT.THEME
  GROUP BY RT.SURVEY_ID, RT.THEME
)
SELECT * FROM ALL_THEMES
WHERE RESPONSES >= 5;

-- Fix 2 for existing results (new runs do this automatically)
UPDATE RESPONSES_ENRICHED
   SET SENTIMENT_SCORE = CASE SENTIMENT_LABEL
         WHEN 'positive' THEN 1 WHEN 'negative' THEN -1
         WHEN 'neutral' THEN 0 WHEN 'mixed' THEN 0
         ELSE SENTIMENT_SCORE END;

-- Expected: percentages add up to less than 100, and sentiment is clearly below 0
SELECT THEME, RESPONSES, PCT_OF_SURVEY, AVG_SENTIMENT FROM V_THEME_SUMMARY ORDER BY RESPONSES DESC;
