# Give a pilot client their own link

Each client logs in to the same Survey Analyzer app with their own login. They only see their own surveys, they must confirm consent before uploading, and their raw answers are deleted automatically after 30 days (you can change this per client).

## One-time setup (about 10 minutes)

1. In your workspace, click **Pull**, open `sql/06_clients.sql` and choose **Run All**. This also makes you the app's admin.
2. Update the app: open **Projects → Streamlit → Survey Analyzer → Edit**, replace the code with `streamlit/streamlit_app.py`, and click **Run**. You should still see every survey.
3. Let clients open the app. In a worksheet, run:

```sql
SHOW STREAMLITS IN SCHEMA SURVEY_ANALYZER.CORE;
-- copy the "name" value from the result, then:
GRANT USAGE ON STREAMLIT SURVEY_ANALYZER.CORE.<NAME> TO ROLE SURVEY_CLIENT;
```

## For each new client (about 3 minutes)

1. Copy the "Adding a pilot client" block at the bottom of `sql/06_clients.sql` into a worksheet. Remove the `--` at the start of each line, change the login name, temporary password, client code and client name, and click **Run All**.
2. Copy the app link: open the app and copy the address from your browser.
3. Send the client the link and the login name. Send the temporary password separately, for example by phone or a different message. They will be asked to choose a new password the first time they log in.

## What the client sees

- A **Results** tab with themes, sentiment and charts for their own surveys only.
- An **Add data** tab where they upload a CSV with a `response_text` column, after ticking the consent box.
- A **Manage** tab where they can delete a survey at any time.

## Good to know

- Everything still runs in your Snowflake account, so you pay for their usage. The XS warehouse and the 10-credit monthly cap still apply.
- The Snowflake trial ends around Dec 18. Pilots need a paid Snowflake account after that.
- If you see "This login has no access yet" as admin, tell Claude: the app could not read your login name and needs a small change.
