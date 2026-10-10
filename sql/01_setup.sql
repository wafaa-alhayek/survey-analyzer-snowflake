-- =====================================================================
-- Survey Analyzer on Snowflake Cortex
-- 01_setup.sql : warehouse, database, credit guardrails, tables
-- Run in a Snowsight SQL worksheet as ACCOUNTADMIN (trial default role).
-- =====================================================================

USE ROLE ACCOUNTADMIN;

-- ---------------------------------------------------------------------
-- 1. Credit guardrails
--    XS warehouse = 1 credit per running hour, billed per second.
--    It suspends after 60 seconds idle, so a demo costs cents.
--    The resource monitor hard-stops the warehouse at 10 credits/month.
--    Note: Cortex AI calls are billed separately from the warehouse
--    (per token) and are NOT stopped by a resource monitor. The prototype
--    sample uses well under 0.1 credit of Cortex per run.
-- ---------------------------------------------------------------------
CREATE RESOURCE MONITOR IF NOT EXISTS SURVEY_MONITOR
  WITH CREDIT_QUOTA = 10
  FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 75 PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND_IMMEDIATE;

CREATE WAREHOUSE IF NOT EXISTS SURVEY_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Survey analyzer prototype';

ALTER WAREHOUSE SURVEY_WH SET RESOURCE_MONITOR = SURVEY_MONITOR;

-- ---------------------------------------------------------------------
-- 2. Database and schema
-- ---------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS SURVEY_ANALYZER;
CREATE SCHEMA IF NOT EXISTS SURVEY_ANALYZER.CORE;

USE WAREHOUSE SURVEY_WH;
USE SCHEMA SURVEY_ANALYZER.CORE;

-- ---------------------------------------------------------------------
-- 3. Tables
-- ---------------------------------------------------------------------

-- Raw responses exactly as collected. Contains personal data:
-- restrict access and delete it once analysis is finished.
-- TRANSIENT + 0 days retention means deleted rows are gone for good
-- (no Time Travel copy, no 7-day Fail-safe copy).
CREATE TRANSIENT TABLE IF NOT EXISTS RESPONSES_RAW (
  RESPONSE_ID    STRING        NOT NULL,
  SURVEY_ID      STRING        NOT NULL,
  QUESTION       STRING,
  RESPONSE_TEXT  STRING        NOT NULL,
  REGION         STRING,
  AGE_GROUP      STRING,
  LOADED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
DATA_RETENTION_TIME_IN_DAYS = 0;

-- One row per response after AI processing. Only redacted text is kept.
CREATE TABLE IF NOT EXISTS RESPONSES_ENRICHED (
  RESPONSE_ID      STRING,
  SURVEY_ID        STRING,
  REGION           STRING,
  AGE_GROUP        STRING,
  LANGUAGE         STRING,
  TEXT_REDACTED    STRING,   -- original language, personal details removed
  TEXT_EN          STRING,   -- English translation of the redacted text
  SENTIMENT_LABEL  STRING,   -- positive / neutral / negative / mixed
  SENTIMENT_SCORE  FLOAT,    -- -1 (negative) to 1 (positive)
  TOPICS           ARRAY,    -- short topic phrases from the model
  MODEL            STRING,
  PROCESSED_AT     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Themes discovered for each survey.
CREATE TABLE IF NOT EXISTS THEMES (
  SURVEY_ID    STRING,
  THEME        STRING,
  DESCRIPTION  STRING,
  CREATED_AT   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Theme assigned to each response.
CREATE TABLE IF NOT EXISTS RESPONSE_THEMES (
  RESPONSE_ID  STRING,
  SURVEY_ID    STRING,
  THEME        STRING
);

-- Quick check that Cortex works in this account and region.
-- Expected: a short sentence. If you see "model unavailable", see docs/SETUP.md.
SELECT SNOWFLAKE.CORTEX.COMPLETE('llama3.1-70b', 'Reply with the words: Cortex is ready.') AS CORTEX_CHECK;
