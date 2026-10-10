# Setup in Snowsight (about 15 minutes)

You need: your Snowflake trial login. The trial user has the ACCOUNTADMIN role, which is all this needs.

## 1. Create the warehouse, database and tables

1. Log in to Snowsight and open **Projects → Worksheets → + (SQL Worksheet)**.
2. Paste the whole of [`sql/01_setup.sql`](../sql/01_setup.sql) and click the arrow next to **Run** and choose **Run All**.
3. The last result should say something like *"Cortex is ready."*

If the last step says the model is unavailable in your region, try `'mistral-large2'` or `'llama3.1-8b'` in that query. If none work, your trial region has no Cortex models. Snowflake can route the call to another region with `ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';` but that sends text outside your region, so for sensitive data prefer making a new trial in a region such as AWS US West 2 (Oregon) or AWS Europe Central 1 (Frankfurt).

## 2. Load the synthetic sample survey

Paste [`sql/02_sample_data.sql`](../sql/02_sample_data.sql) into a new worksheet and **Run All**. You should see 10 responses in each of 4 regions. All 40 responses are invented (20 English, 20 Arabic), and four contain fake names, phone numbers and emails to show redaction.

## 3. Create and run the analysis

Paste [`sql/03_pipeline.sql`](../sql/03_pipeline.sql) and **Run All**. The `CALL RUN_ANALYSIS(...)` line takes one to three minutes and returns a line like:

```
Analyzed 40 responses into 6 themes with llama3.1-70b. Responses the model could not read: 0.
```

The two queries after it show the themes and every response with its redacted text, translation, sentiment and theme. Check that the four sample rows with personal details now show `[NAME]`, `[PHONE]` or `[EMAIL]`.

## 4. Create the reporting views

Paste [`sql/04_report_views.sql`](../sql/04_report_views.sql) and **Run All**. You should see a theme table with only themes that have 5 or more responses.

## 5. Create the Streamlit app

1. In Snowsight open **Projects → Streamlit → + Streamlit App**.
2. Name: `Survey Analyzer`. Location: database `SURVEY_ANALYZER`, schema `CORE`. Warehouse: `SURVEY_WH`. Click **Create**.
3. Delete the example code in the editor, paste all of [`streamlit/streamlit_app.py`](../streamlit/streamlit_app.py), and click **Run**.
4. Pick `DEMO_NEEDS_2026` in the sidebar to see the results.

## 6. Try your own data

In the app's **Add data** tab, upload a CSV with a `response_text` column (optional: `question`, `region`, `age_group`). You can test with [`data/sample_responses.csv`](../data/sample_responses.csv). Then choose the new survey in the sidebar and click **Run analysis**.

## Keeping credit use small

- The warehouse is Extra Small (1 credit per hour) and suspends after 60 seconds idle.
- A resource monitor suspends it if it reaches 10 credits in a month.
- Cortex model calls are billed separately per token and are not covered by the resource monitor. One run on the 40-row sample is a few thousand tokens per response, well under 0.1 credit with `llama3.1-70b`. `llama3.1-8b` is cheaper again.
- Close the Streamlit tab when you are done: an open app keeps the warehouse awake.
- To check spending: **Admin → Cost Management**, or run
  `SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY ORDER BY USAGE_DATE DESC;`
  (this view can lag by a few hours).

## When you are finished with a survey

Click **Delete survey data** in the app's **Manage** tab, or run `CALL SURVEY_ANALYZER.CORE.DELETE_SURVEY('MY_SURVEY_2026');`.

## Troubleshooting

| What you see | What to do |
|---|---|
| `Unknown model` or `model unavailable` | Switch model in the sidebar, or see step 1. |
| `Responses the model could not read: N` above 0 | Those rows keep the pattern-redacted text without translation. Re-run, or try `mistral-large2`. |
| Only "Other" themes | The theme step got unreadable output. Re-run the analysis. |
| Streamlit says a view does not exist | Run `sql/04_report_views.sql`. |
| Upload button errors on Arabic text | Save the CSV as "CSV UTF-8" in Excel. |
