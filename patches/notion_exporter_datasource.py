#!/usr/bin/env python3
"""
Idempotently patches the installed notion-exporter==0.1.1 (exporter.py).

Why: 0.1.1 only treats `database_id` parents as database rows and reads
`properties["title"]` for everything else. Notion now reports rows of
databases as `data_source_id` parents, and their title column has a
different name (e.g. "Name"), so export fails with KeyError: 'title'.

Changes:
  1. Pages with a `data_source_id` parent are handled like `database_id`.
  2. Title = first property whose type == "title" (any column name).
     If there is no title text, fall back to "Untitled-<id8>".
  3. Per-page failure isolation: a page whose metadata or content fetch
     raises is logged, recorded in `_FAILED_PAGES`, and skipped instead of
     aborting the whole export.

Run with the venv python. Safe to run repeatedly: it exits 0 if the file is
already patched. Exits non-zero if the file does not match the expected
0.1.1 source (so a silent mis-patch is impossible).
"""
import importlib.util
import py_compile
import sys

MARKER = "# [patched: datasource/title/safe]"


def find_exporter_path() -> str:
    spec = importlib.util.find_spec("notion_exporter")
    if spec is None or not spec.submodule_search_locations:
        sys.exit("notion_exporter is not installed in this Python environment")
    import os
    return os.path.join(list(spec.submodule_search_locations)[0], "exporter.py")


def replace_once(src: str, old: str, new: str, label: str) -> str:
    count = src.count(old)
    if count != 1:
        sys.exit(f"[{label}] expected exactly 1 match in exporter.py, found {count}; "
                 "installed notion-exporter does not match 0.1.1, refusing to patch")
    return src.replace(old, new)


# --- 1. Title lookup and data_source_id handling -----------------------------
OLD_TITLE = '''        properties = {}
        if page_object["parent"]["type"] == "database_id":
            title = ""
            for prop_name, prop in page_object["properties"].items():
                if prop["type"] == "title":
                    title = prop["title"][0]["plain_text"] if prop["title"] else ""
                properties[prop_name] = self.property_converter.convert_property(prop)

        else:
            title = (
                page_object["properties"]["title"]["title"][0]["plain_text"]
                if page_object["properties"]["title"]["title"]
                else ""
            )
'''
NEW_TITLE = f'''        properties = {{}}
        {MARKER}
        if page_object["parent"]["type"] in ("database_id", "data_source_id"):
            title = ""
            for prop_name, prop in page_object["properties"].items():
                if prop["type"] == "title":
                    title = "".join(t.get("plain_text", "") for t in prop["title"])
                properties[prop_name] = self.property_converter.convert_property(prop)

        else:
            title_prop = next(
                (p for p in page_object["properties"].values() if p.get("type") == "title"), None
            )
            title = "".join(t.get("plain_text", "") for t in title_prop["title"]) if title_prop else ""
        if not title.strip():
            title = f"Untitled-{{page_object['id'].replace('-', '')[:8]}}"
'''

# --- 2. Per-page failure isolation inside _async_export_pages ----------------
OLD_GATHER = '''            page_meta_tasks = [self._get_page_meta(page_id) for page_id in page_ids]
            page_content_tasks = [self._get_block_content(page_id) for page_id in page_ids]
            page_details_results = await asyncio.gather(*page_meta_tasks)
            page_content_results = await asyncio.gather(*page_content_tasks)
            ids_to_exclude.update(page["page_id"] for page in page_details_results)

            for page_details, (markdown, child_page_ids, child_database_ids) in zip(
                page_details_results, page_content_results
            ):
'''
NEW_GATHER = '''            page_meta_tasks = [self._safe_call(self._get_page_meta(page_id), "page", page_id) for page_id in page_ids]
            page_content_tasks = [
                self._safe_call(self._get_block_content(page_id), "content", page_id) for page_id in page_ids
            ]
            page_details_results = await asyncio.gather(*page_meta_tasks)
            page_content_results = await asyncio.gather(*page_content_tasks)
            ids_to_exclude.update(page["page_id"] for page in page_details_results if page)

            for page_details, page_content in zip(page_details_results, page_content_results):
                if page_details is None or page_content is None:
                    continue
                markdown, child_page_ids, child_database_ids = page_content
'''

OLD_BLOCK_CONTENT_DEF = "    async def _get_block_content(\n"
NEW_BLOCK_CONTENT_DEF = '''    async def _safe_call(self, coro, kind: str, item_id: str):
        """Await one page fetch; on failure log, record, and return None (skip page)."""
        try:
            return await coro
        except Exception as exc:
            msg = f"{type(exc).__name__}: {exc}"
            logger.error(f"SKIPPED {kind} {item_id}: {msg}")
            _FAILED_PAGES.append({"kind": kind, "id": item_id, "error": msg})
            return None

    async def _get_block_content(
'''

OLD_LOGGER = 'logger = logging.getLogger(__name__)\n'
NEW_LOGGER = 'logger = logging.getLogger(__name__)\n' + MARKER + '\n_FAILED_PAGES: list[dict] = []\n'


def main() -> None:
    path = find_exporter_path()
    with open(path, encoding="utf-8") as f:
        src = f.read()

    if MARKER in src:
        print(f"already patched: {path}")
        return

    src = replace_once(src, OLD_TITLE, NEW_TITLE, "title")
    src = replace_once(src, OLD_GATHER, NEW_GATHER, "gather")
    src = replace_once(src, OLD_BLOCK_CONTENT_DEF, NEW_BLOCK_CONTENT_DEF, "safe_call")
    src = replace_once(src, OLD_LOGGER, NEW_LOGGER, "failed_pages")

    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    py_compile.compile(path, doraise=True)
    print(f"patched: {path}")


if __name__ == "__main__":
    main()
