"""Fill missing documentation vectors using the configured OpenAI-style endpoint."""

import argparse
import json
import math
from urllib.request import Request, urlopen

import psycopg


def embeddings(endpoint, model, dimensions, texts):
    request = Request(endpoint, data=json.dumps({"model": model, "input": texts}).encode(),
                      headers={"Content-Type": "application/json"})
    with urlopen(request, timeout=60) as response:
        rows = sorted(json.load(response)["data"], key=lambda row: row["index"])
    if [row["index"] for row in rows] != list(range(len(texts))):
        raise ValueError("The endpoint returned unexpected embedding indexes")
    vectors = [row["embedding"] for row in rows]
    if not all(len(v) == dimensions and any(v) and all(math.isfinite(x) for x in v) for v in vectors):
        raise ValueError("The endpoint returned an invalid embedding")
    return vectors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dsn", default="", help="libpq DSN or libpq environment settings")
    args = parser.parse_args()
    with psycopg.connect(args.dsn) as conn:
        profile = conn.execute(
            "SELECT endpoint, model, dimensions FROM ai.doc_embedding_profile WHERE profile='default'"
        ).fetchone()
        if profile is None:
            parser.error("Configure the default embedding profile first")
        endpoint, model, dimensions = profile
        pending = conn.execute("""
            SELECT server_major, section_url, page_number, chunk_number, title, excerpt
            FROM ai.postgres_doc_chunk
            WHERE embedding_model IS DISTINCT FROM %s OR cardinality(embedding) IS DISTINCT FROM %s
            ORDER BY server_major, section_url, page_number, chunk_number
        """, (model, dimensions)).fetchall()
        conn.commit()
        count = 0
        for start in range(0, len(pending), 16):
            batch = pending[start:start + 16]
            vectors = embeddings(endpoint, model, dimensions, [
                "passage: " + row[-2] + "\n" + row[-1] for row in batch
            ])
            with conn.cursor() as cursor:
                cursor.executemany("""
                    UPDATE ai.postgres_doc_chunk SET embedding_model=%s, embedding=%s
                    WHERE (server_major, section_url, page_number, chunk_number)=(%s,%s,%s,%s)
                      AND title=%s AND excerpt=%s
                      AND (embedding_model IS DISTINCT FROM %s OR cardinality(embedding) IS DISTINCT FROM %s)
                """, [(model, vector, *row, model, dimensions)
                      for row, vector in zip(batch, vectors, strict=True)])
                count += cursor.rowcount
            conn.commit()
    print(f"Embedded {count} excerpts with {model}.")


if __name__ == "__main__":
    main()
