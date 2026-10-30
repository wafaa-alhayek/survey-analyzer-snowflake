-- =====================================================================
-- 07_publish_app.sql : publish the app where pilot clients can open it
--
-- An app deployed from a personal workspace lives in your private
-- USER$ database, and nobody else can be given access to it. This file
-- creates a shared copy in SURVEY_ANALYZER.CORE straight from GitHub,
-- running on the XS warehouse, and lets the SURVEY_CLIENT role open it.
-- Run once as ACCOUNTADMIN, after 06_clients.sql. Run it again whenever
-- Claude changes streamlit/streamlit_app.py, to publish the new version.
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE SURVEY_WH;

-- Read-only access to the public GitHub repo (no login needed while it is public)
CREATE API INTEGRATION IF NOT EXISTS GITHUB_PUBLIC
  API_PROVIDER = git_https_api
  API_ALLOWED_PREFIXES = ('https://github.com/wafaa-alhayek')
  ENABLED = TRUE;

CREATE GIT REPOSITORY IF NOT EXISTS SURVEY_ANALYZER.CORE.APP_REPO
  API_INTEGRATION = GITHUB_PUBLIC
  ORIGIN = 'https://github.com/wafaa-alhayek/survey-analyzer-snowflake.git';

-- Get the latest files from GitHub
ALTER GIT REPOSITORY SURVEY_ANALYZER.CORE.APP_REPO FETCH;

-- The shared app
CREATE OR REPLACE STREAMLIT SURVEY_ANALYZER.CORE.SURVEY_APP
  FROM '@SURVEY_ANALYZER.CORE.APP_REPO/branches/main/streamlit/'
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = SURVEY_WH
  TITLE = 'Survey Analyzer by Describe';

ALTER STREAMLIT SURVEY_ANALYZER.CORE.SURVEY_APP ADD LIVE VERSION FROM LAST;

-- Pilot clients may open it
GRANT USAGE ON STREAMLIT SURVEY_ANALYZER.CORE.SURVEY_APP TO ROLE SURVEY_CLIENT;

SHOW STREAMLITS IN SCHEMA SURVEY_ANALYZER.CORE;
