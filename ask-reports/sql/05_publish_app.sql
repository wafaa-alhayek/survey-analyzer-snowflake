-- =====================================================================
-- 05_publish_app.sql : publish the "Ask your reports" app
--
-- Creates the app straight from GitHub, running on the XS warehouse
-- (warehouse runtime, not a compute pool), and lets the Survey
-- Analyzer's pilot clients (role SURVEY_CLIENT) open it.
-- Run once as ACCOUNTADMIN after 04_search.sql. Run it again whenever
-- Claude changes ask-reports/streamlit/, to publish the new version.
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE SURVEY_WH;

ALTER GIT REPOSITORY SURVEY_ANALYZER.CORE.APP_REPO FETCH;

CREATE OR REPLACE STREAMLIT ASK_REPORTS.CORE.ASK_APP
  FROM '@SURVEY_ANALYZER.CORE.APP_REPO/branches/main/ask-reports/streamlit/'
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = SURVEY_WH
  TITLE = 'Ask your reports by Describe';

ALTER STREAMLIT ASK_REPORTS.CORE.ASK_APP ADD LIVE VERSION FROM LAST;

-- Pilot clients may open the app. The app runs as its owner, so clients
-- get no direct access to the tables or the PDFs.
GRANT USAGE ON DATABASE ASK_REPORTS    TO ROLE SURVEY_CLIENT;
GRANT USAGE ON SCHEMA ASK_REPORTS.CORE TO ROLE SURVEY_CLIENT;
GRANT USAGE ON STREAMLIT ASK_REPORTS.CORE.ASK_APP TO ROLE SURVEY_CLIENT;

SHOW STREAMLITS IN SCHEMA ASK_REPORTS.CORE;
