# stops the server $rpl_server_number names.
# MySQL 8.1 moved the replication includes under include/rpl and renamed them, so
# this picks the one the running server ships and keeps the result the same on every server.
#
# neither include can use the include framework, since its server goes away, so both ignore
# include_silent and print their name only when sourced at the top level.  raising the depth
# around them keeps that line out of the result on every server.
--let $_tdb_rpl_legacy = `SELECT VERSION() LIKE '8.0.%'`
--inc $_include_file_depth
if ($_tdb_rpl_legacy)
{
  --source include/rpl_stop_server.inc
}
if (!$_tdb_rpl_legacy)
{
  --source include/rpl/stop_server.inc
}
--dec $_include_file_depth
