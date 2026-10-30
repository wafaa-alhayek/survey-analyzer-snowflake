-- =====================================================================
-- 06_check_spend.sql : what has the trial credit gone on?
--
-- Run any time as ACCOUNTADMIN. Account usage views lag by up to a few
-- hours, so today's numbers fill in later. Dollars assume $3 a credit,
-- the usual trial (Enterprise) price; Snowsight > Admin > Cost
-- management shows the exact figure and the credit left.
-- Budget for this app: about $30 to $70 of the trial credit.
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE SURVEY_WH;

-- 1. Last 30 days by service: warehouses, AI (Cortex), search, etc.
SELECT SERVICE_TYPE,
       ROUND(SUM(CREDITS_BILLED), 3)     AS CREDITS,
       ROUND(SUM(CREDITS_BILLED) * 3, 2) AS APPROX_USD
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE USAGE_DATE >= DATEADD(day, -30, CURRENT_DATE())
GROUP BY SERVICE_TYPE
ORDER BY CREDITS DESC;

-- 2. Day by day, to spot a jump
SELECT USAGE_DATE,
       ROUND(SUM(CREDITS_BILLED), 3)     AS CREDITS,
       ROUND(SUM(CREDITS_BILLED) * 3, 2) AS APPROX_USD
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE USAGE_DATE >= DATEADD(day, -30, CURRENT_DATE())
GROUP BY USAGE_DATE
ORDER BY USAGE_DATE DESC;

-- 3. Is search awake? (serving_state ACTIVE = billed, SUSPENDED = asleep)
SHOW CORTEX SEARCH SERVICES IN SCHEMA ASK_REPORTS.CORE;

-- 4. How many questions were answered from saved answers (no LLM call)
SELECT IFF(ANSWERED_BY = 'SAVED', 'Saved answer', 'LLM: ' || ANSWERED_BY) AS ANSWERED_BY,
       COUNT(*) AS QUESTIONS,
       ROUND(AVG(SECONDS), 1) AS AVG_SECONDS
FROM ASK_REPORTS.CORE.QUESTION_LOG
GROUP BY 1
ORDER BY 2 DESC;

-- To put search to sleep right now:   CALL ASK_REPORTS.CORE.SLEEP_SEARCH();
-- To wake it:                          CALL ASK_REPORTS.CORE.WAKE_SEARCH();
