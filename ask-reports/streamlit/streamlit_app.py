"""
Ask your reports: Streamlit in Snowflake app.

Clients upload PDFs and ask questions in Arabic or English. Every answer
cites the document and page it came from. Everything runs inside this
Snowflake account: PARSE_DOCUMENT reads the PDFs, Cortex Search finds the
right pages, and a Cortex LLM writes the answer.

Questions close to one of the saved questions drafted when a document was
loaded are answered straight away by an embedding match, without the LLM.
Published by ask-reports/sql/05_publish_app.sql.
"""
import html
import io
import json
import re
import time

import streamlit as st
from snowflake.snowpark.context import get_active_session

DB = "ASK_REPORTS.CORE"
CLIENTS_DB = "SURVEY_ANALYZER.CORE"  # shared client list with the Survey Analyzer
SEARCH_SERVICE = f"{DB}.REPORTS_SEARCH"
EMBED_MODEL = "snowflake-arctic-embed-l-v2.0"  # must match sql/02_ingest.sql
# Checked on this account (AWS us-east-2) on 30 Oct 2026; mistral-large2 is not available here
MODELS = ["claude-sonnet-4-5", "llama3.3-70b", "llama3.1-70b"]
FALLBACK_MODEL = "llama3.3-70b"
SAVED_MATCH = 0.86  # same-language cosine similarity needed to reuse a saved answer
TOP_K = 6  # page chunks given to the LLM
MAX_MB = 50
ARABIC = re.compile(r"[؀-ۿ]")

session = get_active_session()
st.set_page_config(page_title="Ask your reports", layout="wide")


def query(sql, params=None):
    return session.sql(sql, params=params or []).to_pandas()


def scalar(sql, params=None):
    return session.sql(sql, params=params or []).collect()[0][0]


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
IS_ADMIN = not query(f"SELECT 1 FROM {CLIENTS_DB}.APP_ADMINS WHERE UPPER(SNOWFLAKE_USER) = ?", [VIEWER]).empty
client_row = query(
    f"SELECT CLIENT_ID, CLIENT_NAME FROM {CLIENTS_DB}.CLIENTS WHERE UPPER(SNOWFLAKE_USER) = ?", [VIEWER]
)
CLIENT = None if client_row.empty else client_row.iloc[0]

st.title("Ask your reports")
if not IS_ADMIN and CLIENT is None:
    st.error("This login has no access yet. Please contact Describe.")
    st.stop()
st.caption(
    "Ask in Arabic or English. Answers come only from the documents in the collection, "
    "and every answer shows the page it came from. Documents never leave this Snowflake account."
)


# ---------------------------------------------------------------- data
def collections():
    if IS_ADMIN:
        return query(f"SELECT COLLECTION, TITLE, CLIENT_ID FROM {DB}.COLLECTIONS ORDER BY CLIENT_ID NULLS FIRST, 1")
    return query(
        f"SELECT COLLECTION, TITLE, CLIENT_ID FROM {DB}.COLLECTIONS "
        "WHERE CLIENT_ID IS NULL OR CLIENT_ID = ? ORDER BY CLIENT_ID NULLS FIRST, 1",
        [CLIENT["CLIENT_ID"]],
    )


def documents(coll):
    return query(
        f"SELECT DOC_ID, TITLE, PAGE_COUNT, STATUS, ERROR, SOURCE_URL FROM {DB}.DOCUMENTS "
        "WHERE COLLECTION = ? ORDER BY TITLE",
        [coll],
    )


def can_edit(coll_row):
    if IS_ADMIN:
        return True
    return CLIENT is not None and coll_row["CLIENT_ID"] == CLIENT["CLIENT_ID"]


def doc_links(doc_ids):
    """Link per document: the public source if known, else a 1-hour private link."""
    links = {}
    for doc_id in set(doc_ids):
        row = query(f"SELECT SOURCE_URL FROM {DB}.DOCUMENTS WHERE DOC_ID = ?", [doc_id])
        public = None if row.empty else row.iloc[0]["SOURCE_URL"]
        if public:
            links[doc_id] = public
            continue
        try:
            links[doc_id] = scalar(f"SELECT GET_PRESIGNED_URL(@{DB}.DOCS, ?, 3600)", [doc_id])
        except Exception:
            links[doc_id] = None
    return links


# ---------------------------------------------------------------- answering
def match_saved(question, coll, language):
    """Closest saved question in this collection, compared in the question's own language."""
    emb, text = ("Q_EMB_AR", "QUESTION_AR") if language == "Arabic" else ("Q_EMB", "QUESTION")
    df = query(
        f"""
        WITH Q AS (SELECT SNOWFLAKE.CORTEX.EMBED_TEXT_1024(?, ?) AS E)
        SELECT S.{text} AS QUESTION, S.ANSWER_EN, S.ANSWER_AR, S.PAGES, S.DOC_ID, D.TITLE,
               VECTOR_COSINE_SIMILARITY(S.{emb}, Q.E) AS SIM
        FROM {DB}.SAVED_ANSWERS S
        JOIN {DB}.DOCUMENTS D ON D.DOC_ID = S.DOC_ID
        CROSS JOIN Q
        WHERE S.COLLECTION = ? AND S.{emb} IS NOT NULL
        ORDER BY SIM DESC
        LIMIT 1
        """,
        [EMBED_MODEL, question, coll],
    )
    return None if df.empty else df.iloc[0]


def search(question, coll):
    """Top page chunks from Cortex Search. Wakes the service if it is asleep."""
    payload = json.dumps(
        {
            "query": question,
            "columns": ["CHUNK_TEXT", "TITLE", "DOC_ID", "PAGE_NO"],
            "filter": {"@eq": {"COLLECTION": coll}},
            "limit": TOP_K,
        },
        ensure_ascii=False,
    ).replace("$$", "$ $")
    sql = f"SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW('{SEARCH_SERVICE}', $${payload}$$)"
    for attempt in range(8):
        try:
            return json.loads(scalar(sql)).get("results", [])
        except Exception as exc:
            if attempt == 0:
                st.info("Search was asleep to save credit. Waking it up, this takes about a minute...")
                try:
                    session.sql(f"CALL {DB}.WAKE_SEARCH()").collect()
                except Exception:
                    raise exc
            time.sleep(10)
    raise RuntimeError("Search did not wake up. Please try again in a few minutes.")


def build_prompt(question, coll_title, hits, language):
    excerpts = "\n\n".join(
        f"[{i}] {h['TITLE']}, page {h['PAGE_NO']}:\n{h['CHUNK_TEXT']}" for i, h in enumerate(hits, 1)
    )
    return (
        f'You answer questions using only the numbered excerpts below, taken from the document collection "{coll_title}".\n'
        "Rules:\n"
        f"- Answer in {language}.\n"
        "- End every sentence that states a fact with its excerpt number in square brackets, like [2].\n"
        "- Copy numbers, dates and names of places exactly as written in the excerpts.\n"
        "- If the excerpts do not answer the question, say so plainly and do not guess.\n"
        "- If excerpts disagree (for example two report dates), give both with their numbers.\n"
        "- At most 200 words.\n\n"
        f"Excerpts:\n{excerpts}\n\nQuestion: {question}"
    )


def complete(model, prompt):
    """Run the chosen model; fall back to one available in every region."""
    for m in dict.fromkeys([model, FALLBACK_MODEL]):
        out = scalar("SELECT SNOWFLAKE.CORTEX.TRY_COMPLETE(?, ?)", [m, prompt])
        if out:
            return out.strip(), m
    raise RuntimeError("No language model answered. Check that Cortex is enabled in this account.")


def answer(question, coll, coll_title, model, fresh=False):
    t0 = time.time()
    language = "Arabic" if ARABIC.search(question) else "English"

    if not fresh:
        saved = match_saved(question, coll, language)
        if saved is not None and float(saved["SIM"]) >= SAVED_MATCH:
            pages = json.loads(saved["PAGES"]) if isinstance(saved["PAGES"], str) else list(saved["PAGES"] or [])
            text = saved["ANSWER_AR"] if language == "Arabic" and saved["ANSWER_AR"] else saved["ANSWER_EN"]
            sources = [{"n": i, "TITLE": saved["TITLE"], "DOC_ID": saved["DOC_ID"], "PAGE_NO": p}
                       for i, p in enumerate(pages, 1)]
            result = {
                "text": text, "sources": sources, "by": "SAVED", "language": language,
                "note": f'Saved answer to a similar question: "{saved["QUESTION"]}" (match {float(saved["SIM"]):.2f})',
            }
            log(question, coll, "SAVED", time.time() - t0)
            return result

    hits = search(question, coll)
    if not hits:
        text = "لم أجد شيئاً عن هذا في المستندات." if language == "Arabic" else "I found nothing about this in the documents."
        return {"text": text, "sources": [], "by": "SEARCH", "language": language, "note": ""}
    text, used = complete(model, build_prompt(question, coll_title, hits, language))
    cited = {int(n) for n in re.findall(r"\[(\d+)\]", text)}
    sources = [{"n": i, **h} for i, h in enumerate(hits, 1) if not cited or i in cited]
    log(question, coll, used, time.time() - t0)
    return {"text": text, "sources": sources, "by": used, "language": language, "note": ""}


def log(question, coll, by, seconds):
    try:
        session.sql(
            f"INSERT INTO {DB}.QUESTION_LOG (SNOWFLAKE_USER, COLLECTION, QUESTION, ANSWERED_BY, SECONDS) "
            "VALUES (?, ?, ?, ?, ?)",
            params=[VIEWER, coll, question, by, round(seconds, 2)],
        ).collect()
    except Exception:
        pass


def show(result):
    body = html.escape(result["text"]).replace("\n", "<br>")
    if result["language"] == "Arabic":
        st.markdown(f'<div dir="rtl" style="text-align:right">{body}</div>', unsafe_allow_html=True)
    else:
        st.markdown(f"<div>{body}</div>", unsafe_allow_html=True)
    if result["note"]:
        st.caption(result["note"])
    if result["sources"]:
        links = doc_links([s["DOC_ID"] for s in result["sources"]])
        lines = []
        for s in result["sources"]:
            url = links.get(s["DOC_ID"])
            label = f"{s['TITLE']}, page {s['PAGE_NO']}"
            lines.append(f"[{s['n']}] [{label}]({url}#page={s['PAGE_NO']})" if url else f"[{s['n']}] {label}")
        st.markdown("**Sources**  \n" + "  \n".join(lines))
        excerpts = [s for s in result["sources"] if s.get("CHUNK_TEXT")]
        if excerpts:
            with st.expander("Show the text these answers came from"):
                for s in excerpts:
                    st.markdown(f"**[{s['n']}] {s['TITLE']}, page {s['PAGE_NO']}**")
                    st.text(s["CHUNK_TEXT"][:1500])


# ---------------------------------------------------------------- sidebar
colls = collections()
with st.sidebar:
    st.header("Collection")
    if colls.empty:
        st.info("No collections yet.")
        st.stop()
    titles = dict(zip(colls["COLLECTION"], colls["TITLE"].fillna(colls["COLLECTION"])))
    coll = st.selectbox("Search in", list(titles), format_func=lambda c: titles[c])
    coll_row = colls[colls["COLLECTION"] == coll].iloc[0]
    if IS_ADMIN:
        model = st.selectbox("Model", MODELS, help=f"Claude writes the best Arabic. If it does not answer, {FALLBACK_MODEL} is used.")
    else:
        model = MODELS[0]

    docs = documents(coll)
    ready = docs[docs["STATUS"] == "READY"]
    st.caption(f"{len(ready)} documents, {int(ready['PAGE_COUNT'].fillna(0).sum())} pages")
    with st.expander("Documents"):
        for _, d in docs.iterrows():
            line = f"{d['TITLE']} ({int(d['PAGE_COUNT'] or 0)} pages)"
            if d["STATUS"] != "READY":
                line += f" - {d['STATUS']}: {d['ERROR'] or ''}"
            st.write(line)
            if can_edit(coll_row) and st.button("Delete", key=f"del_{d['DOC_ID']}"):
                session.sql(f"CALL {DB}.DELETE_DOCUMENT(?)", params=[d["DOC_ID"]]).collect()
                st.rerun()

    # Upload. Clients add to their own collection; admins to any.
    st.header("Add PDFs")
    if IS_ADMIN:
        target = st.text_input("Collection (existing or new)", value=coll).strip().upper()
        target = re.sub(r"[^A-Z0-9_]", "_", target)
        target_client = None if target in titles else st.text_input("Client code for a new collection (blank = visible to all)").strip().upper() or None
    else:
        target, target_client = CLIENT["CLIENT_ID"], CLIENT["CLIENT_ID"]
        st.caption(f"Your documents go into your private collection, {target}.")
    files = st.file_uploader("PDF files", type=["pdf"], accept_multiple_files=True)
    consent = st.checkbox(
        "These documents contain no personal or patient data, and I may share them with Describe for this pilot."
    )
    if files and st.button("Upload and read", disabled=not consent, type="primary"):
        session.sql(
            f"MERGE INTO {DB}.COLLECTIONS T USING (SELECT ? AS C, ? AS CL) S ON T.COLLECTION = S.C "
            "WHEN NOT MATCHED THEN INSERT (COLLECTION, TITLE, CLIENT_ID) VALUES (S.C, S.C, S.CL)",
            params=[target, target_client],
        ).collect()
        for f in files:
            if f.size > MAX_MB * 1024 * 1024:
                st.warning(f"{f.name} is over {MAX_MB} MB and was skipped.")
                continue
            name = re.sub(r"[^A-Za-z0-9._-]", "_", f.name)
            doc_id = f"{target}/{name}"
            session.file.put_stream(io.BytesIO(f.getvalue()), f"@{DB}.DOCS/{doc_id}", auto_compress=False, overwrite=True)
            session.sql(
                f"MERGE INTO {DB}.DOCUMENTS T USING (SELECT ? AS D) S ON T.DOC_ID = S.D "
                "WHEN MATCHED THEN UPDATE SET STATUS = 'NEW', ERROR = NULL, UPLOADED_BY = ?, LOADED_AT = CURRENT_TIMESTAMP() "
                "WHEN NOT MATCHED THEN INSERT (DOC_ID, COLLECTION, FILE_NAME, TITLE, STATUS, UPLOADED_BY) "
                "VALUES (S.D, ?, ?, ?, 'NEW', ?)",
                params=[doc_id, VIEWER, target, name, re.sub(r"[_-]+", " ", name[:-4]), VIEWER],
            ).collect()
        with st.spinner("Reading the PDFs page by page. About a minute per 20 pages..."):
            msg = scalar(f"CALL {DB}.INGEST(?)", [model])
        st.success(msg)
        st.rerun()

# ---------------------------------------------------------------- main
history = st.session_state.setdefault("history", {}).setdefault(coll, [])

saved_qs = query(
    f"SELECT QUESTION FROM {DB}.SAVED_ANSWERS WHERE COLLECTION = ? ORDER BY RANDOM() LIMIT 4", [coll]
) if not history else None
if saved_qs is not None and not saved_qs.empty:
    st.write("Try asking:")
    cols = st.columns(len(saved_qs))
    for c, q in zip(cols, saved_qs["QUESTION"]):
        if c.button(q, use_container_width=True):
            st.session_state["pending"] = q

for i, turn in enumerate(history):
    with st.chat_message("user"):
        st.write(turn["question"])
    with st.chat_message("assistant"):
        show(turn["result"])
        if turn["result"]["by"] == "SAVED" and st.button("Ask the model fresh instead", key=f"fresh_{coll}_{i}"):
            st.session_state["pending_fresh"] = turn["question"]

question = st.chat_input("Ask a question in Arabic or English / اسأل بالعربية أو الإنجليزية")
fresh = False
if st.session_state.get("pending_fresh"):
    question, fresh = st.session_state.pop("pending_fresh"), True
elif st.session_state.get("pending"):
    question = st.session_state.pop("pending")

if question:
    with st.chat_message("user"):
        st.write(question)
    with st.chat_message("assistant"):
        with st.spinner("Searching the documents..."):
            try:
                result = answer(question, coll, titles[coll], model, fresh=fresh)
            except Exception as exc:
                st.error(f"Something went wrong: {exc}")
                st.stop()
        show(result)
    history.append({"question": question, "result": result})
    st.rerun()
