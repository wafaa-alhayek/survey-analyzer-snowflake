-- =====================================================================
-- 04_report_views.sql : privacy-safe reporting views
-- Every view reports on groups only. Any group with fewer than 5
-- responses is hidden so no individual can be singled out.
-- To change the threshold, replace 5 below and re-run this file.
-- =====================================================================

USE WAREHOUSE SURVEY_WH;
USE SCHEMA SURVEY_ANALYZER.CORE;

-- Headline numbers per survey
CREATE OR REPLACE VIEW V_SURVEY_OVERVIEW COPY GRANTS AS
SELECT
  SURVEY_ID,
  COUNT(*)                                            AS RESPONSES,
  COUNT_IF(LANGUAGE = 'ar')                           AS ARABIC,
  COUNT_IF(LANGUAGE = 'en')                           AS ENGLISH,
  COUNT_IF(LANGUAGE NOT IN ('ar', 'en'))              AS OTHER_LANGUAGE,
  ROUND(AVG(SENTIMENT_SCORE), 2)                      AS AVG_SENTIMENT,
  ROUND(100 * COUNT_IF(SENTIMENT_LABEL = 'negative') / COUNT(*), 0) AS PCT_NEGATIVE,
  MAX(PROCESSED_AT)                                   AS LAST_RUN
FROM RESPONSES_ENRICHED
GROUP BY SURVEY_ID
HAVING COUNT(*) >= 5;

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

-- Sentiment by region (hidden where a region has fewer than 5 responses)
CREATE OR REPLACE VIEW V_SENTIMENT_BY_REGION COPY GRANTS AS
SELECT
  SURVEY_ID,
  COALESCE(REGION, 'Not given')                                       AS REGION,
  COUNT(*)                                                            AS RESPONSES,
  ROUND(AVG(SENTIMENT_SCORE), 2)                                      AS AVG_SENTIMENT,
  ROUND(100 * COUNT_IF(SENTIMENT_LABEL = 'negative') / COUNT(*), 0)   AS PCT_NEGATIVE
FROM RESPONSES_ENRICHED
GROUP BY SURVEY_ID, COALESCE(REGION, 'Not given')
HAVING COUNT(*) >= 5;

-- Theme x region counts (small cells hidden)
CREATE OR REPLACE VIEW V_THEME_BY_REGION COPY GRANTS AS
SELECT
  RT.SURVEY_ID,
  COALESCE(E.REGION, 'Not given') AS REGION,
  RT.THEME,
  COUNT(*)                        AS RESPONSES
FROM RESPONSE_THEMES RT
JOIN RESPONSES_ENRICHED E
  ON E.RESPONSE_ID = RT.RESPONSE_ID AND E.SURVEY_ID = RT.SURVEY_ID
GROUP BY RT.SURVEY_ID, COALESCE(E.REGION, 'Not given'), RT.THEME
HAVING COUNT(*) >= 5;

-- Up to 3 redacted example quotes per theme, only for themes shown above.
-- Quotes carry no region or age, so they cannot be linked back to a group.
CREATE OR REPLACE VIEW V_THEME_QUOTES COPY GRANTS AS
SELECT RT.SURVEY_ID, RT.THEME, E.LANGUAGE, E.TEXT_REDACTED, E.TEXT_EN, E.SENTIMENT_LABEL
FROM RESPONSE_THEMES RT
JOIN RESPONSES_ENRICHED E
  ON E.RESPONSE_ID = RT.RESPONSE_ID AND E.SURVEY_ID = RT.SURVEY_ID
JOIN V_THEME_SUMMARY S
  ON S.SURVEY_ID = RT.SURVEY_ID AND S.THEME = RT.THEME
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY RT.SURVEY_ID, RT.THEME
  ORDER BY ABS(E.SENTIMENT_SCORE) DESC NULLS LAST
) <= 3;

-- Delete everything for one survey once the work is done:
--   CALL DELETE_SURVEY('DEMO_NEEDS_2026');
CREATE OR REPLACE PROCEDURE DELETE_SURVEY(P_SURVEY_ID STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
  DELETE FROM RESPONSE_THEMES    WHERE SURVEY_ID = :P_SURVEY_ID;
  DELETE FROM THEMES             WHERE SURVEY_ID = :P_SURVEY_ID;
  DELETE FROM RESPONSES_ENRICHED WHERE SURVEY_ID = :P_SURVEY_ID;
  DELETE FROM RESPONSES_RAW      WHERE SURVEY_ID = :P_SURVEY_ID;
  RETURN 'Deleted all data for survey ' || P_SURVEY_ID || '.';
END;
$$;

SELECT * FROM V_THEME_SUMMARY ORDER BY RESPONSES DESC;
