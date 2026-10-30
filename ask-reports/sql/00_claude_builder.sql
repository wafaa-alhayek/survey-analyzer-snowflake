-- =====================================================================
-- 00_claude_builder.sql : let Claude build and fix "Ask your reports"
--
-- Today Claude's Snowflake login (CLAUDE_USER) can only read the four
-- survey summary views. This gives it a new role, CLAUDE_BUILDER, that
-- can create, run and fix everything inside the ASK_REPORTS database,
-- and nothing outside it:
--   - owns the ASK_REPORTS database (tables, stage, search, app)
--   - reads the client list and the GitHub copy of the repo
--   - uses SURVEY_WH (capped at 10 credits a month by SURVEY_MONITOR)
--   - reads credit usage, but not other people's queries
-- It cannot touch SURVEY_ANALYZER data, users, roles or account settings.
-- Cortex AI calls are billed per use and not capped by the monitor.
--
-- Run once as ACCOUNTADMIN, BEFORE 01_setup.sql. Then Claude runs
-- files 01 to 05 itself. Undo everything with the block at the end.
-- =====================================================================

USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS CLAUDE_BUILDER;
GRANT ROLE CLAUDE_READER TO ROLE CLAUDE_BUILDER;   -- keeps the old read access
GRANT ROLE CLAUDE_BUILDER TO ROLE ACCOUNTADMIN;    -- you still see everything it makes
GRANT ROLE CLAUDE_BUILDER TO USER CLAUDE_USER;
ALTER USER CLAUDE_USER SET DEFAULT_ROLE = CLAUDE_BUILDER;

-- Its own database
CREATE DATABASE IF NOT EXISTS ASK_REPORTS;
GRANT OWNERSHIP ON DATABASE ASK_REPORTS TO ROLE CLAUDE_BUILDER COPY CURRENT GRANTS;
CREATE SCHEMA IF NOT EXISTS ASK_REPORTS.CORE;
GRANT OWNERSHIP ON SCHEMA ASK_REPORTS.CORE TO ROLE CLAUDE_BUILDER COPY CURRENT GRANTS;

-- Warehouse, scheduled tasks, Cortex, credit usage
GRANT USAGE, OPERATE ON WAREHOUSE SURVEY_WH TO ROLE CLAUDE_BUILDER;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE CLAUDE_BUILDER;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE CLAUDE_BUILDER;
GRANT DATABASE ROLE SNOWFLAKE.USAGE_VIEWER TO ROLE CLAUDE_BUILDER;

-- Read the client list (the app shows each client only their documents)
GRANT USAGE ON DATABASE SURVEY_ANALYZER TO ROLE CLAUDE_BUILDER;
GRANT USAGE ON SCHEMA SURVEY_ANALYZER.CORE TO ROLE CLAUDE_BUILDER;
GRANT SELECT ON TABLE SURVEY_ANALYZER.CORE.CLIENTS TO ROLE CLAUDE_BUILDER;
GRANT SELECT ON TABLE SURVEY_ANALYZER.CORE.APP_ADMINS TO ROLE CLAUDE_BUILDER;

-- Read the GitHub copy of the repo (demo PDFs and app code), and fetch updates
GRANT READ, WRITE ON GIT REPOSITORY SURVEY_ANALYZER.CORE.APP_REPO TO ROLE CLAUDE_BUILDER;

-- As owner of ASK_REPORTS it can also share the app with SURVEY_CLIENT
-- (05_publish_app.sql), without any account-wide grant rights.

-- Claude's connector: allow the new role and switch the tool from
-- read-only to read-write. The tool name stays run_sql.
CREATE OR REPLACE MCP SERVER SURVEY_ANALYZER.CORE.CLAUDE_MCP
  FROM SPECIFICATION $$
    tools:
      - title: "Run SQL"
        name: "run_sql"
        type: "SYSTEM_EXECUTE_SQL"
        description: "Run SQL as CLAUDE_BUILDER: build and run the Ask your reports app in ASK_REPORTS.CORE, and read the survey summary views in SURVEY_ANALYZER.CORE."
        config:
          read_only: false
          query_timeout: 600
          warehouse: "SURVEY_WH"
  $$;
GRANT USAGE ON MCP SERVER SURVEY_ANALYZER.CORE.CLAUDE_MCP TO ROLE CLAUDE_READER;
GRANT USAGE ON MCP SERVER SURVEY_ANALYZER.CORE.CLAUDE_MCP TO ROLE CLAUDE_BUILDER;
ALTER SECURITY INTEGRATION CLAUDE_OAUTH SET ALLOWED_ROLES_LIST = ('CLAUDE_READER', 'CLAUDE_BUILDER');

SHOW GRANTS TO ROLE CLAUDE_BUILDER;

-- ---------------------------------------------------------------------
-- To undo everything later (as ACCOUNTADMIN):
--   ALTER USER CLAUDE_USER SET DEFAULT_ROLE = CLAUDE_READER;
--   REVOKE ROLE CLAUDE_BUILDER FROM USER CLAUDE_USER;
--   ALTER SECURITY INTEGRATION CLAUDE_OAUTH SET ALLOWED_ROLES_LIST = ('CLAUDE_READER');
--   GRANT OWNERSHIP ON DATABASE ASK_REPORTS TO ROLE ACCOUNTADMIN COPY CURRENT GRANTS;
--   DROP ROLE CLAUDE_BUILDER;
-- ---------------------------------------------------------------------
