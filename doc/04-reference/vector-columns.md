---
title: Vector Columns
description: Why a VECTOR column works in a TidesDB table, what it actually costs, and why similarity search over it is a full scan rather than an index.
---

# Vector Columns

A TidesDB table can hold `VECTOR` columns on Percona Server 9.7, the first supported line whose
server has the type; 8.0 and 8.4 do not parse it. That is worth stating plainly because it is not a
feature the engine implements — it is a consequence of how the server models the type.

`VECTOR` is a blob type. In the server, `Field_vector` derives from `Field_blob` and inherits its
`BLOB_FLAG`, and the engine keys its blob handling off exactly that flag. A vector therefore reaches
the row codec as the bytes it is and is stored, read back and re-encoded by the same code that
handles `BLOB` and `TEXT`. There is no vector-specific line anywhere in TideSQL, and none in the
TidesDB library either.

What follows from that is the useful part: everything true of a blob column is true of a vector one.

```sql
CREATE TABLE embeddings (
  id    INT NOT NULL PRIMARY KEY,
  title VARCHAR(200),
  v     VECTOR(384) NOT NULL,
  KEY title_idx (title)
) ENGINE=TIDESDB;

INSERT INTO embeddings VALUES (1, 'cat picture', STRING_TO_VECTOR('[0.1, 0.9, ...]'));

SELECT id, title, VECTOR_TO_STRING(v), VECTOR_DIM(v) FROM embeddings;
```

`STRING_TO_VECTOR` (also spelled `TO_VECTOR`) parses the text form, `VECTOR_TO_STRING` (also
`FROM_VECTOR`) renders it back, and `VECTOR_DIM` reports the dimension. A vector whose dimension does
not match the column is refused with `ER_DATA_TOO_LONG`.

A vector survives updates, deletes and restarts byte for byte, sits happily in a table reached
through a secondary index on another column, and is covered by the row format's versioning, so a
table whose shape changed still reads its older rows back. A large vector crosses the value-log
threshold like any other large value, which means it is written once and left out of later merges;
see [Table Options](/reference/table-options) for the threshold and how to opt a table out of it.

## Similarity search is a full scan

The distance function is the server's own and works on any column it can read, so a similarity
query over a TidesDB table runs, ranked by the server over a full scan:

```sql
SELECT id, title FROM embeddings
  ORDER BY DISTANCE(v, STRING_TO_VECTOR('[0.1, 0.9, ...]'), 'EUCLIDEAN') LIMIT 10;
```

`VECTOR_DISTANCE` is the same function. Every row is read and measured, so the cost grows with the
table; that is fine for thousands of rows and the wrong tool for millions.

There is no index that would make the query approximate and fast. Percona Server 9.7.2 has no vector
index for any engine, InnoDB included, so the syntax does not parse:

```sql
CREATE TABLE t (id INT PRIMARY KEY, v VECTOR(4) NOT NULL, VECTOR INDEX (v)) ENGINE=TIDESDB;
-- ERROR 1064 (42000): You have an error in your SQL syntax; ...
```

Any other index on the column is refused too, whichever spelling is used — `KEY (v)`,
`FULLTEXT KEY (v)` and `SPATIAL KEY (v)` are all rejected with `ER_NON_SCALAR_USED_AS_KEY` (6134),
because a vector is not a scalar the server can order.

The suite carries a test that fails the day a server accepts a vector index on a TidesDB table, so
that change is noticed rather than missed.

## What that costs

An exact scan over every vector is `O(rows)` and reads each row's full value, the value log included.
Narrowing first is what makes it affordable — a `WHERE` on an indexed column, a time window, a tenant
id — so the distance computation runs over a bounded candidate set rather than the whole table. The
[optimizer chapter](/internals/optimizer) covers how the engine costs those scans.
