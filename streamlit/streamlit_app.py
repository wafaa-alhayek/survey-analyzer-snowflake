"""
Survey Analyzer: Streamlit in Snowflake app.

Paste this file into a new Streamlit app in Snowsight (see docs/SETUP.md).
Everything runs inside your Snowflake account: the app reads only the
privacy-safe views, and analysis runs on Snowflake Cortex models.
"""
import re
import uuid

import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

DB = "SURVEY_ANALYZER.CORE"
MIN_GROUP = 5  # must match the threshold in sql/04_report_views.sql
MODELS = ["llama3.1-70b", "mistral-large2", "llama3.3-70b", "llama3.1-8b"]

session = get_active_session()
st.set_page_config(page_title="Survey Analyzer", layout="wide")


def query(sql, params=None):
    return session.sql(sql, params=params or []).to_pandas()


def viewer_name():
    """Login name of the person viewing the app (not the app owner)."""
    for attr in ("user", "experimental_user"):
        info = getattr(st, attr, None)
        if info is None:
            continue
        for key in ("user_name", "login_name"):
            try:
                value = info.get(key) if hasattr(info, "get") else getattr(info, key, None)
            except Exception:
                value = None
            if value:
                return str(value).upper()
    return ""


VIEWER = viewer_name()
IS_ADMIN = not query(f"SELECT 1 FROM {DB}.APP_ADMINS WHERE UPPER(SNOWFLAKE_USER) = ?", [VIEWER]).empty
client_row = query(
    f"SELECT CLIENT_ID, CLIENT_NAME, RETENTION_DAYS FROM {DB}.CLIENTS WHERE UPPER(SNOWFLAKE_USER) = ?",
    [VIEWER],
)
CLIENT = None if client_row.empty else client_row.iloc[0]


def surveys():
    if IS_ADMIN:
        df = query(
            f"SELECT SURVEY_ID FROM {DB}.SURVEYS UNION SELECT DISTINCT SURVEY_ID FROM {DB}.RESPONSES_RAW ORDER BY 1"
        )
    else:
        df = query(f"SELECT SURVEY_ID FROM {DB}.SURVEYS WHERE CLIENT_ID = ? ORDER BY 1", [CLIENT["CLIENT_ID"]])
    return df["SURVEY_ID"].tolist()


st.title("Survey Analyzer by Describe")
if not IS_ADMIN and CLIENT is None:
    # Unknown logins see nothing. Add them to CLIENTS or APP_ADMINS first.
    st.error("This login has no access yet. Please contact Describe.")
    st.stop()
st.caption(
    "Responses never leave this Snowflake account. Personal details are removed "
    f"before analysis, and groups smaller than {MIN_GROUP} are hidden."
)
if CLIENT is not None:
    st.caption(
        f"Signed in for {CLIENT['CLIENT_NAME']}. Raw answers are deleted automatically "
        f"{int(CLIENT['RETENTION_DAYS'])} days after upload."
    )

# ---------------------------------------------------------------- sidebar
with st.sidebar:
    st.header("Survey")
    options = surveys()
    if not options:
        st.info("No surveys yet. Load one in the 'Add data' tab.")
        survey = None
    else:
        survey = st.selectbox("Choose a survey", options)
    if IS_ADMIN:
        model = st.selectbox(
            "Model",
            MODELS,
            help="llama3.1-70b is a good default for Arabic and English. "
            "llama3.1-8b is cheapest but weaker at Arabic.",
        )
    else:
        model = MODELS[0]
    if survey and st.button("Run analysis", type="primary"):
        with st.spinner("Analyzing responses with Cortex. This takes a minute or two..."):
            result = session.call(f"{DB}.RUN_ANALYSIS", survey, model)
        st.success(result)

if "loaded_msg" in st.session_state:
    st.success(st.session_state.pop("loaded_msg"))

tab_results, tab_add, tab_manage = st.tabs(["Results", "Add data", "Manage"])

# ---------------------------------------------------------------- results
with tab_results:
    overview = (
        query(f"SELECT * FROM {DB}.V_SURVEY_OVERVIEW WHERE SURVEY_ID = ?", [survey])
        if survey
        else pd.DataFrame()
    )
    if not survey:
        st.info("Load a survey in the 'Add data' tab to get started.")
    elif overview.empty:
        st.info("This survey has not been analyzed yet. Click 'Run analysis' in the sidebar.")
    else:
        o = overview.iloc[0]
        c1, c2, c3, c4 = st.columns(4)
        c1.metric("Responses analyzed", int(o["RESPONSES"]))
        c2.metric("Arabic / English", f"{int(o['ARABIC'])} / {int(o['ENGLISH'])}")
        c3.metric("Average sentiment (-1 to 1)", f"{o['AVG_SENTIMENT']:.2f}")
        c4.metric("Negative responses", f"{int(o['PCT_NEGATIVE'])}%")

        themes = query(
            f"SELECT THEME, DESCRIPTION, RESPONSES, PCT_OF_SURVEY, AVG_SENTIMENT, "
            f"PCT_NEGATIVE, ARABIC, ENGLISH FROM {DB}.V_THEME_SUMMARY "
            f"WHERE SURVEY_ID = ? ORDER BY RESPONSES DESC",
            [survey],
        )
        st.subheader("Themes")
        hidden = int(o["RESPONSES"]) - int(themes["RESPONSES"].sum() if not themes.empty else 0)
        if themes.empty:
            st.warning(f"No theme has {MIN_GROUP} or more responses yet.")
        else:
            st.bar_chart(themes.set_index("THEME")["RESPONSES"])
            st.dataframe(themes, use_container_width=True)
        if hidden > 0:
            st.caption(f"{hidden} responses belong to themes with fewer than {MIN_GROUP} responses and are hidden.")

        st.subheader("Sentiment by region")
        regions = query(
            f"SELECT REGION, RESPONSES, AVG_SENTIMENT, PCT_NEGATIVE FROM {DB}.V_SENTIMENT_BY_REGION "
            f"WHERE SURVEY_ID = ? ORDER BY REGION",
            [survey],
        )
        if regions.empty:
            st.caption(f"No region has {MIN_GROUP} or more responses.")
        else:
            st.bar_chart(regions.set_index("REGION")["AVG_SENTIMENT"])
            st.dataframe(regions, use_container_width=True)

        st.subheader("Themes by region")
        by_region = query(
            f"SELECT REGION, THEME, RESPONSES FROM {DB}.V_THEME_BY_REGION WHERE SURVEY_ID = ?",
            [survey],
        )
        if by_region.empty:
            st.caption(f"Every region and theme combination has fewer than {MIN_GROUP} responses, so all are hidden.")
        else:
            st.dataframe(
                by_region.pivot_table(index="THEME", columns="REGION", values="RESPONSES", fill_value=0),
                use_container_width=True,
            )

        if st.checkbox("Show example quotes (personal details removed)"):
            quotes = query(
                f"SELECT THEME, LANGUAGE, TEXT_REDACTED, TEXT_EN, SENTIMENT_LABEL "
                f"FROM {DB}.V_THEME_QUOTES WHERE SURVEY_ID = ? ORDER BY THEME",
                [survey],
            )
            for theme, group in quotes.groupby("THEME"):
                with st.expander(theme):
                    for _, q in group.iterrows():
                        st.markdown(f"> {q['TEXT_REDACTED']}")
                        if q["LANGUAGE"] != "en" and q["TEXT_EN"]:
                            st.caption(f"English: {q['TEXT_EN']}")

        csv = themes.to_csv(index=False).encode("utf-8")
        st.download_button("Download theme summary (CSV)", csv, f"{survey}_themes.csv", "text/csv")

# ---------------------------------------------------------------- add data
with tab_add:
    st.subheader("Load a CSV of responses")
    st.markdown(
        "Required column: `response_text`. Optional columns: `question`, `region`, `age_group`. "
        "UTF-8 encoding works for Arabic. Do not include names or contact columns."
    )
    name = st.text_input("Survey name (letters, numbers, underscores)", "MY_SURVEY_2026")
    new_id = re.sub(r"[^A-Z0-9_]", "", name.strip().upper().replace(" ", "_"))
    if CLIENT is not None:
        # Prefix keeps each client's surveys apart
        new_id = f"{CLIENT['CLIENT_ID']}_{new_id}"
    taken = new_id in surveys() or not query(
        f"SELECT 1 FROM {DB}.SURVEYS WHERE SURVEY_ID = ?", [new_id]
    ).empty
    if taken:
        st.warning(f"A survey called {new_id} already exists. Choose another name.")
    consent = st.checkbox(
        "I confirm that every respondent gave informed consent for their answers to be analyzed, "
        "and that the file contains no names, phone numbers or other contact details."
    )
    upload = st.file_uploader("CSV file", type=["csv"])
    if upload is not None:
        df = pd.read_csv(upload, dtype=str)
        df.columns = [c.strip().lower() for c in df.columns]
        if "response_text" not in df.columns:
            st.error("The file needs a column named response_text.")
        else:
            keep = [c for c in ["question", "response_text", "region", "age_group"] if c in df.columns]
            df = df[keep].dropna(subset=["response_text"])
            st.write(f"{len(df)} responses found. First rows:")
            st.dataframe(df.head(5), use_container_width=True)
            if st.button("Load into Snowflake", disabled=not consent or taken or not new_id):
                df.insert(0, "survey_id", new_id)
                df.insert(0, "response_id", [str(uuid.uuid4()) for _ in range(len(df))])
                df.columns = [c.upper() for c in df.columns]
                session.create_dataframe(df).write.save_as_table(
                    f"{DB}.RESPONSES_RAW", mode="append", column_order="name"
                )
                session.sql(
                    f"INSERT INTO {DB}.SURVEYS (SURVEY_ID, CLIENT_ID, CONSENT_CONFIRMED) VALUES (?, ?, TRUE)",
                    params=[new_id, None if CLIENT is None else CLIENT["CLIENT_ID"]],
                ).collect()
                st.session_state["loaded_msg"] = (
                    f"Loaded {len(df)} responses into {new_id}. Pick it in the sidebar and click Run analysis."
                )
                st.rerun()  # redraw so the sidebar lists the new survey

# ---------------------------------------------------------------- manage
with tab_manage:
    st.subheader("Delete a survey")
    st.markdown(
        "Removes the raw responses, the processed results and the themes for one survey. "
        "Raw responses are stored without backup copies, so this cannot be undone."
    )
    if survey:
        confirm = st.checkbox(f"I want to permanently delete all data for {survey}")
        if confirm and st.button("Delete survey data"):
            st.success(session.call(f"{DB}.DELETE_SURVEY", survey))
            session.sql(f"DELETE FROM {DB}.SURVEYS WHERE SURVEY_ID = ?", params=[survey]).collect()
