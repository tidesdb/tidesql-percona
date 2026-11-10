/*
  Copyright (c) 2026 TidesDB Corp.

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; version 2 of the License.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301  USA
*/

#ifndef HA_TIDESDB_FK_CHILD_H
#define HA_TIDESDB_FK_CHILD_H

#include <string>

#include "ha_tidesdb.h"

/* a cascade needs the child table open to find and rewrite the rows that reference the parent.
   from MySQL 9.6 the server opens every cascaded child for the statement and the cascade finds it
   among the statement's tables.  before that the server only takes the child's metadata lock while
   it prelocks the statement, and the cascade opens the child itself, here, under that lock. */

/**
 * tdb_fk_child_table
 * a private open of a foreign key's child table, held for one cascade and closed when it goes out
 * of scope
 * @param thd the session the child was opened for, or NULL while nothing is open
 * @param share the child's share, referenced while the table is open
 * @param table the private table instance and its handler
 * @param locked whether the handler holds its write lock and must release it on close
 */
class tdb_fk_child_table
{
   public:
    tdb_fk_child_table() = default;
    ~tdb_fk_child_table();
    tdb_fk_child_table(const tdb_fk_child_table &) = delete;
    tdb_fk_child_table &operator=(const tdb_fk_child_table &) = delete;

    /**
     * open
     * open the child for writing, provided the statement already holds its metadata lock
     * @param thd the session running the cascade
     * @param db the child's database
     * @param tbl the child's table name
     * @return the open table, or NULL when the lock is not held or the table cannot be opened, in
     *         which case the caller treats the child as unreachable
     */
    TABLE *open(THD *thd, const std::string &db, const std::string &tbl);

   private:
    void close();

    THD *thd_ = nullptr;
    TABLE_SHARE *share_ = nullptr;
    TABLE table_;
    bool locked_ = false;
};

#endif /* HA_TIDESDB_FK_CHILD_H */
