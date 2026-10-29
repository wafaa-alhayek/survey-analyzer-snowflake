-- =====================================================================
-- 06_clients.sql : let pilot clients use the app through a link
--
-- Each client gets their own Snowflake login. In the Streamlit app they
-- see only their own surveys, must confirm consent before uploading, and
-- their raw answers are deleted automatically after RETENTION_DAYS.
-- Run once as ACCOUNTADMIN, after files 01 to 05.
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE SURVEY_WH;
USE SCHEMA SURVEY_ANALYZER.CORE;

-- Who the clients are, and which Snowflake login belongs to each
CREATE TABLE IF NOT EXISTS CLIENTS (
  CLIENT_ID       STRING NOT NULL,   -- short code, e.g. 'UNI_GAZA'
  CLIENT_NAME     STRING,
  SNOWFLAKE_USER  STRING NOT NULL,   -- the login name, in capitals
  RETENTION_DAYS  INTEGER DEFAULT 30,
  CREATED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Who may see every survey and use the admin controls.
-- Whoever runs this file is added automatically.
CREATE TABLE IF NOT EXISTS APP_ADMINS (SNOWFLAKE_USER STRING NOT NULL);
INSERT INTO APP_ADMINS
SELECT CURRENT_USER() WHERE NOT EXISTS (SELECT 1 FROM APP_ADMINS WHERE SNOWFLAKE_USER = CURRENT_USER());

-- Which survey belongs to which client
CREATE TABLE IF NOT EXISTS SURVEYS (
  SURVEY_ID          STRING NOT NULL,
  CLIENT_ID          STRING,         -- NULL = your own (admin) surveys
  CONSENT_CONFIRMED  BOOLEAN,
  CREATED_AT         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- The demo survey is yours
INSERT INTO SURVEYS (SURVEY_ID, CLIENT_ID, CONSENT_CONFIRMED)
SELECT 'DEMO_NEEDS_2026', NULL, TRUE
WHERE NOT EXISTS (SELECT 1 FROM SURVEYS WHERE SURVEY_ID = 'DEMO_NEEDS_2026');

-- Role every client login gets. It can only open the app.
CREATE ROLE IF NOT EXISTS SURVEY_CLIENT;
GRANT USAGE ON DATABASE SURVEY_ANALYZER    TO ROLE SURVEY_CLIENT;
GRANT USAGE ON SCHEMA SURVEY_ANALYZER.CORE TO ROLE SURVEY_CLIENT;
-- After creating the Streamlit app, also run (use your app's name):
--   SHOW STREAMLITS IN SCHEMA SURVEY_ANALYZER.CORE;
--   GRANT USAGE ON STREAMLIT SURVEY_ANALYZER.CORE.<APP_NAME> TO ROLE SURVEY_CLIENT;

-- Automatic deletion of raw answers once a client's retention period ends
CREATE OR REPLACE PROCEDURE PURGE_EXPIRED()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  n INTEGER DEFAULT 0;
  c CURSOR FOR
    SELECT S.SURVEY_ID
    FROM SURVEYS S
    JOIN CLIENTS C ON C.CLIENT_ID = S.CLIENT_ID
    WHERE S.CREATED_AT < DATEADD(day, -C.RETENTION_DAYS, CURRENT_TIMESTAMP());
BEGIN
  FOR r IN c DO
    LET sid STRING := r.SURVEY_ID;
    CALL DELETE_SURVEY(:sid);
    DELETE FROM SURVEYS WHERE SURVEY_ID = :sid;
    n := n + 1;
  END FOR;
  RETURN 'Deleted ' || n || ' expired surveys.';
END;
$$;

-- Runs once a day at 02:00 UTC (a few seconds of the XS warehouse)
CREATE OR REPLACE TASK PURGE_EXPIRED_DAILY
  WAREHOUSE = SURVEY_WH
  SCHEDULE = 'USING CRON 0 2 * * * UTC'
AS
  CALL PURGE_EXPIRED();

ALTER TASK PURGE_EXPIRED_DAILY RESUME;

-- ---------------------------------------------------------------------
-- Adding a pilot client: copy this block, change the 4 marked values,
-- and run it. Send the client the app link, the login name and the
-- temporary password (by a different channel than the link).
-- ---------------------------------------------------------------------
-- CREATE USER UNI_GAZA_1                          -- <-- login name
--   PASSWORD = 'Temporary-Password-123!'          -- <-- temporary password
--   MUST_CHANGE_PASSWORD = TRUE
--   DEFAULT_ROLE = SURVEY_CLIENT
--   DEFAULT_WAREHOUSE = SURVEY_WH;
-- GRANT ROLE SURVEY_CLIENT TO USER UNI_GAZA_1;
-- INSERT INTO CLIENTS (CLIENT_ID, CLIENT_NAME, SNOWFLAKE_USER, RETENTION_DAYS)
-- VALUES ('UNI_GAZA', 'Example University', 'UNI_GAZA_1', 30);  -- <-- client code, name

SHOW TASKS LIKE 'PURGE_EXPIRED_DAILY';
