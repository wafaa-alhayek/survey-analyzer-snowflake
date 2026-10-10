# Connect Claude to your Snowflake account

After this, Claude can query your Snowflake data directly in chat ("which theme has the most negative responses?").

**Privacy first.** Anything Claude reads through this connection is sent to Claude. So the setup below gives Claude a separate, read-only Snowflake login that can only see the privacy-safe summary views, never the raw survey answers.

It takes about 15 minutes in two parts: Snowflake (part A), then Claude (part B).

---

## Part A: in Snowflake

### A1. Find your account URL

1. Log in to Snowflake at https://app.snowflake.com.
2. At the **bottom of the left sidebar**, click your **name or initials**.
3. Hover over your account name, then click **View account details** (on some versions: **Account → Copy account URL**).
4. Copy the **Account/Server URL**. It looks like `abcdefg-xy12345.snowflakecomputing.com`.
   If it contains an underscore `_`, replace each `_` with a hyphen `-`.

Write it down. You will use it in step A4 and part B.

### A2. Open a SQL worksheet

In the left sidebar click **Projects → Worksheets**, then the **+** button (top right) → **SQL Worksheet**.

### A3. Paste and run this SQL

Change the two lines marked `<-- CHANGE`, then click the small arrow next to the blue **Run** button and choose **Run All**.

```sql
USE ROLE ACCOUNTADMIN;

-- 1. A read-only role that can only see the summary views
CREATE ROLE IF NOT EXISTS CLAUDE_READER;
GRANT USAGE ON WAREHOUSE SURVEY_WH            TO ROLE CLAUDE_READER;
GRANT USAGE ON DATABASE SURVEY_ANALYZER       TO ROLE CLAUDE_READER;
GRANT USAGE ON SCHEMA SURVEY_ANALYZER.CORE    TO ROLE CLAUDE_READER;
GRANT SELECT ON VIEW SURVEY_ANALYZER.CORE.V_SURVEY_OVERVIEW     TO ROLE CLAUDE_READER;
GRANT SELECT ON VIEW SURVEY_ANALYZER.CORE.V_THEME_SUMMARY       TO ROLE CLAUDE_READER;
GRANT SELECT ON VIEW SURVEY_ANALYZER.CORE.V_SENTIMENT_BY_REGION TO ROLE CLAUDE_READER;
GRANT SELECT ON VIEW SURVEY_ANALYZER.CORE.V_THEME_BY_REGION     TO ROLE CLAUDE_READER;
-- Example quotes are redacted but still real sentences. Leave this out for sensitive surveys:
-- GRANT SELECT ON VIEW SURVEY_ANALYZER.CORE.V_THEME_QUOTES TO ROLE CLAUDE_READER;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_AGENT_USER TO ROLE CLAUDE_READER;

-- 2. A separate login for Claude (you sign in as this user once, in part B)
CREATE USER IF NOT EXISTS CLAUDE_USER
  PASSWORD = 'Choose-A-Long-Password-123!'   -- <-- CHANGE, and save it somewhere safe
  DEFAULT_ROLE = CLAUDE_READER
  DEFAULT_WAREHOUSE = SURVEY_WH
  MUST_CHANGE_PASSWORD = FALSE;
GRANT ROLE CLAUDE_READER TO USER CLAUDE_USER;

-- 3. The MCP server: one tool that runs read-only SQL
CREATE OR REPLACE MCP SERVER SURVEY_ANALYZER.CORE.CLAUDE_MCP
  FROM SPECIFICATION $$
    tools:
      - title: "Run read-only SQL"
        name: "run_sql"
        type: "SYSTEM_EXECUTE_SQL"
        description: "Run read-only SQL on the survey analyzer summary views in SURVEY_ANALYZER.CORE (V_SURVEY_OVERVIEW, V_THEME_SUMMARY, V_SENTIMENT_BY_REGION, V_THEME_BY_REGION)."
        config:
          read_only: true
          query_timeout: 120
          warehouse: "SURVEY_WH"
  $$;
GRANT USAGE ON MCP SERVER SURVEY_ANALYZER.CORE.CLAUDE_MCP TO ROLE CLAUDE_READER;

-- 4. Let Claude sign in with OAuth
CREATE OR REPLACE SECURITY INTEGRATION CLAUDE_OAUTH
  TYPE = OAUTH
  OAUTH_CLIENT = CUSTOM
  ENABLED = TRUE
  OAUTH_CLIENT_TYPE = 'CONFIDENTIAL'
  OAUTH_REDIRECT_URI = 'https://claude.ai/api/mcp/auth_callback'
  OAUTH_USE_SECONDARY_ROLES = NONE
  ALLOWED_ROLES_LIST = ('CLAUDE_READER');

-- 5. Show the Client ID and Client Secret for part B
SELECT SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('CLAUDE_OAUTH');
```

### A4. Copy three values

1. The last result is one cell of text. Click it; the full text appears on the right. Copy the value after `"OAUTH_CLIENT_ID":` and the value after `"OAUTH_CLIENT_SECRET":` (without the quotes). Treat the secret like a password.
2. Build your **server URL** by putting your account URL from A1 into this pattern:

```
https://YOUR-ACCOUNT-URL/api/v2/databases/SURVEY_ANALYZER/schemas/CORE/mcp-servers/CLAUDE_MCP
```

Example: `https://abcdefg-xy12345.snowflakecomputing.com/api/v2/databases/SURVEY_ANALYZER/schemas/CORE/mcp-servers/CLAUDE_MCP`

---

## Part B: in Claude

1. Open https://claude.ai/customize/connectors (or in Claude: click your **name** at the bottom left → **Settings** → **Connectors**).
2. Click **Add custom connector**.
3. **Name:** `Snowflake`. **Remote MCP server URL:** the server URL from A4.
4. Click **Advanced settings** and paste the **OAuth Client ID** and **OAuth Client Secret** from A4.
5. Click **Add**, then **Connect** next to the new Snowflake connector.
6. A Snowflake login window opens. Sign in as **CLAUDE_USER** with the password you chose (not your own login). If Snowflake asks you to set up multi-factor authentication, follow its steps. Approve access.
7. Turn the connector on for this project: open **Project settings → Connectors** and switch **Snowflake** on.
8. Start a new message in the project and ask something like *"Using Snowflake, show the themes in survey DEMO_NEEDS_2026"*.

Note: Claude's directory also lists an official **Snowflake** connector. It uses the same server URL, Client ID and Secret, so you can use it in step 2 instead of "Add custom connector" if you prefer.

---

## If something goes wrong

| What you see | What to do |
|---|---|
| `SQL compilation error` on `CREATE MCP SERVER` | Run files 01 to 04 from the setup guide first, so the database and views exist. |
| `Invalid redirect_uri` in the login window | Check the `OAUTH_REDIRECT_URI` line is exactly `https://claude.ai/api/mcp/auth_callback` and re-run step 4 and 5. |
| Login window says the role is not allowed | You signed in as your own admin user. Sign in as `CLAUDE_USER`. |
| Claude says it cannot connect | Re-check the server URL: hyphens not underscores, and `https://` at the start. |
| "Object does not exist" when Claude queries | Use fully qualified names, e.g. `SURVEY_ANALYZER.CORE.V_THEME_SUMMARY`. |

## To disconnect later

In Claude, remove the connector. In Snowflake run:

```sql
USE ROLE ACCOUNTADMIN;
DROP SECURITY INTEGRATION CLAUDE_OAUTH;
DROP USER CLAUDE_USER;
```
