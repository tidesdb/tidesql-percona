---
title: Server Compatibility
description: Which Percona Server versions TideSQL is tested against, what differs between them, and which capabilities the server offers an engine.
---

# Server Compatibility

TideSQL is built against a server source tree and tracks that server's storage-engine interface, so
a given TideSQL release targets specific server versions. The table records which have been tested
and confirmed working. Full support means the engine is tested against all known functionality on
that server version.

| Server version | Minimum TideSQL version | Full support |
|----------------|-------------------------|:------------:|
| Percona Server 8.0.46-37 | 2.1.0 | Yes |
| Percona Server 8.4.11-11 | 2.1.0 | Yes |
| Percona Server 9.7.2-2 | 2.1.0 | Yes |

Percona's lines after 9.7 are not tested. A plugin is built against one exact server release and
loads only into that release; see [Installing TideSQL](/getting-started/install).

This is the TideSQL 2.x manual and it pairs with TidesDB v10. The current pinned release is 2.1.0,
linking TidesDB v10.2.1, at **beta** maturity. A 2.x minor or patch links a TidesDB v10 release and
extends this same manual, so only a new major opens a new manual. See
[Versioning](https://github.com/tidesdb/tidesql/blob/master/VERSIONING.md) for how the plugin and
the library versions relate.

As versions are tested and confirmed working this table is updated.

## What differs between the lines

One source builds on every line above. Where a server release changed something the engine depends
on, the difference is absorbed at build time, and most of it is invisible from SQL. What is not:

| Behaviour | 8.0 | 8.4 | 9.7 |
|-----------|-----|-----|-----|
| `VECTOR` columns | Not available — the type arrived in 9.0 | Not available | Stored, read back and ranked by `DISTANCE`; no vector index; see [Vector Columns](/reference/vector-columns) |
| Writing InnoDB and TidesDB in one transaction | Allowed | Allowed | Allowed, with deprecation warning 6414 |

Every line shares one difference from stock MySQL. Percona Server refuses a range write or a
locking read at `REPEATABLE READ` inside a multi-statement transaction when the engine reports it
takes no gap locks. TideSQL reports that it does, so those statements run as they would on stock
MySQL; [Transactions and Isolation](/concepts/transactions) says what that means for phantoms.

A cascading foreign key behaves identically on every line, though the server's part in it differs.
From 9.6 the server opens every child table a cascade may reach before the statement starts. Before
that it only takes the child's metadata lock, and the engine opens the child itself, under that
lock, for as long as the cascade runs.

## What the server offers an engine

Some of what a storage engine can do is the engine's own; the rest is whatever the server hands it.
This is the second kind — the capabilities Percona Server does or does not offer, and how TideSQL
reaches each one. The manual says so again at the point each matters:

| Capability | On Percona Server |
|------------|-------------|
| Per-table storage options | Through `ENGINE_ATTRIBUTE`; see [Table Options](/reference/table-options) |
| Per-row expiry column | Through a column's `ENGINE_ATTRIBUTE`; see [Time-To-Live](/reference/ttl) |
| Encryption key custody | A keyring component, two-tier; see [Data-at-Rest Encryption](/reference/encryption) |
| Partitioned tables | Not available; see [Partitioning](/administration/partitioning) |
| System-versioned tables | Not available — the server has no system versioning |
| Multi-primary clustering | Not available; see [Replication and High Availability](/administration/replication-ha) |
| Column histograms | `ANALYZE TABLE ... UPDATE HISTOGRAM`, sampled by the engine; see [Table Maintenance](/administration/maintenance) |
| Bulk load | Not available — the server's loader needs a driver component Percona Server does not ship; see [Limitations](/appendix/limitations) |
| Foreign keys | Enforced by the engine, with the shape restrictions in [Limitations](/appendix/limitations) |

A database written by one TideSQL build is readable by any other at the same version: the column
families, the row format, the key encoding and the engine's own metadata are fixed by the linked
TidesDB release rather than by the server. See
[Versioning](https://github.com/tidesdb/tidesql/blob/master/VERSIONING.md) for the rollback
boundary that follows from it.
