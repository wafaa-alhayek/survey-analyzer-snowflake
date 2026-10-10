# Link your Snowflake Workspace to GitHub

When this is set up, Claude saves file changes to a GitHub repository (a "repo", an online folder that keeps every version of your files), and you click **Pull** in Snowflake to get them. You no longer copy and paste SQL.

There are three parts and they take about 15 minutes.

---

## Part 1: Create an empty repo on GitHub (2 minutes)

1. Go to https://github.com/new and sign in as **wafaa-alhayek**.
2. **Repository name:** `survey-analyzer-snowflake`
3. Choose **Private**.
4. Tick **Add a README file**, so the repo is not completely empty.
5. Click **Create repository**.

## Part 2: Let Claude write to that repo (2 minutes)

1. Go to https://github.com/settings/installations and click **Configure** next to **Claude**.
2. Under **Repository access**, if "Only select repositories" is chosen, add `survey-analyzer-snowflake` and click **Save**. If "All repositories" is chosen, nothing to do.
3. Tell Claude in the thread that the repo is ready. Claude then adds it to the project and uploads all the survey analyzer files.

## Part 3: Connect Snowflake to the repo (10 minutes)

### 3a. Allow Snowflake to talk to GitHub

Open **Projects → Worksheets → +** in Snowflake, paste this, and choose **Run All**:

```sql
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE API INTEGRATION GITHUB_INTEGRATION
  API_PROVIDER = git_https_api
  API_ALLOWED_PREFIXES = ('https://github.com/wafaa-alhayek')
  API_USER_AUTHENTICATION = (TYPE = SNOWFLAKE_GITHUB_APP)
  ENABLED = TRUE;
```

This only allows repos under your own GitHub account.

### 3b. Create the workspace from the repo

1. In the left menu click **Projects → Workspaces**.
2. Click the workspace name menu at the top left and choose **From Git repository**.
3. **Repository URL:** `https://github.com/wafaa-alhayek/survey-analyzer-snowflake`
4. **API Integration:** choose `GITHUB_INTEGRATION`.
5. **Authentication:** choose **OAuth2**, click **Sign in**, then **Authorize Snowflake Computing** on the GitHub page. Allow access to the `survey-analyzer-snowflake` repo and click **Save**.
6. Click **Create**. You will see the `sql`, `streamlit` and `docs` folders.

---

## Everyday use

- **Get Claude's changes:** open the workspace and click **Pull** at the top.
- **Run a file:** open it (for example `sql/05_fixes.sql`) and click **Run All**.
- **Send your own edits back:** click **Changes**, type a short note, and click **Push**. Claude will see them next time.

## If something goes wrong

| What you see | What to do |
|---|---|
| No **From Git repository** option | Workspaces with Git may not be enabled on the trial yet. Tell Claude, and we will keep using copy and paste. |
| OAuth2 is greyed out or sign-in fails | Use a GitHub personal access token instead. Ask Claude for the token steps. |
| `Repository not found` | Check the URL spelling and that you allowed Snowflake access to this repo in step 3b.5. |
| Pull shows nothing new | Claude has not pushed yet, or you are on a different branch. Choose **main**. |
