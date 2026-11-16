"""Import selected sections of the official PostgreSQL 17 documentation PDF."""

import argparse
import re
import textwrap
from pathlib import Path

import psycopg
from pypdf import PdfReader


SECTIONS = {
    "7.2.": ("queries-table-expressions", "соединение агрегация группировка месяц group by left join"),
    "7.4.": ("queries-union", "множества объединение пересечение разность union intersect except"),
    "7.8.": ("queries-with", "cte with подзапрос рекурсия"),
    "9.9.": ("functions-datetime", "дата время месяц помесячный период date_trunc extract date_bin"),
    "9.16.": ("functions-json", "json jsonb документ ключ путь"),
    "9.18.": ("functions-conditional", "условие coalesce nullif case пустой значение"),
    "9.19.": ("functions-array", "массив массивы множества unnest array_agg cardinality array_length"),
    "9.21.": ("functions-aggregate", "агрегат выручка платежи сумма count sum array_agg distinct"),
    "9.22.": ("functions-window", "окно ранжирование row_number rank lag lead"),
    "F.10.": ("cube", "cube cube_distance куб координаты евклидово расстояние вектор gist"),
}


def bookmarks(items, depth=0):
    for item in items:
        if isinstance(item, list):
            yield from bookmarks(item, depth + 1)
        else:
            yield depth, item


def section_boundary(text, section):
    match = re.search(r"(?m)^" + re.escape(section) + r"[ \t]", text)
    if not match:
        raise ValueError(f"Section heading {section} was not found on its PDF page")
    return match.start()


def import_rows(pdf):
    reader = PdfReader(pdf)
    edition = reader.metadata.title or ""
    if not re.fullmatch(r"PostgreSQL 17\.\d+ Documentation", edition):
        raise ValueError(f"Expected the official PostgreSQL 17 documentation PDF, got {edition!r}")

    outline = list(bookmarks(reader.outline))
    sections = {item.title.split()[0]: index for index, (_, item) in enumerate(outline)}
    for section, (slug, keywords) in SECTIONS.items():
        index = sections[section]
        depth, heading = outline[index]
        following = next(item for level, item in outline[index + 1:] if level <= depth)
        start = reader.get_destination_page_number(heading)
        end = reader.get_destination_page_number(following)
        for page in range(start, end + 1):
            content = reader.pages[page].extract_text().replace("\u00a0", " ")
            if page == end:
                next_title = following.title.split()[0]
                boundary = re.search(r"(?m)^" + re.escape(next_title) + r"[ \t]", content)
                if boundary is None and page > start:
                    # The next chapter or appendix begins on its own page.
                    break
                content = content[:boundary.start()] if boundary else content
            if page == start:
                content = content[section_boundary(content, section):]
            content = re.sub(r"\n\d+\s*$", "", content).strip()
            chunks = textwrap.wrap(content, width=1750, replace_whitespace=False)
            for number, excerpt in enumerate(chunks, start=1):
                yield (17, f"https://www.postgresql.org/docs/17/{slug}.html",
                       " ".join(heading.title.split()), edition, page + 1, number, keywords, excerpt)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pdf", type=Path)
    parser.add_argument("--dsn", default="", help="libpq DSN; defaults to libpq environment settings")
    args = parser.parse_args()
    rows = list(import_rows(args.pdf))
    if {row[1].rsplit("/", 1)[1] for row in rows} != {slug + ".html" for slug, _ in SECTIONS.values()}:
        raise ValueError("The PDF extraction did not yield text for all selected sections")
    with psycopg.connect(args.dsn) as connection, connection.cursor() as cursor:
        cursor.execute("LOCK TABLE ai.postgres_doc_chunk IN SHARE ROW EXCLUSIVE MODE")
        cursor.execute("DELETE FROM ai.postgres_doc_chunk WHERE server_major = 17")
        with cursor.copy("""
            COPY ai.postgres_doc_chunk
                (server_major, section_url, title, pdf_edition, page_number, chunk_number, keywords, excerpt)
            FROM STDIN
        """) as copy:
            for row in rows:
                copy.write_row(row)
    print(f"Imported {len(rows)} excerpts from {len(SECTIONS)} sections of {rows[0][3]}.")


if __name__ == "__main__":
    main()
