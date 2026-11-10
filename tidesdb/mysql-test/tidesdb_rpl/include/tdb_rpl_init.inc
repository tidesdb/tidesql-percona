# starts a source and a replica and connects them.
# MySQL 8.1 moved the replication includes under include/rpl and renamed them, so
# this picks the one the running server ships and keeps the result the same on every server.
--let $_tdb_rpl_legacy = `SELECT VERSION() LIKE '8.0.%'`
--let $include_silent = 1
if ($_tdb_rpl_legacy)
{
  --source include/master-slave.inc
}
if (!$_tdb_rpl_legacy)
{
  --source include/rpl/init_source_replica.inc
}
--let $include_silent = 0
