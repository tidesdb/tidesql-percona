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

#include "src/handler/ha_tidesdb_fk_child.h"

#include "mdl.h"
#include "sql_base.h"
#include "sql_class.h"

/* the files a private open asks the handler for: the row data, every index, and the index
   statistics the cascade's index walk reads. */
static constexpr uint TDB_FK_CHILD_OPEN_FILES = HA_OPEN_KEYFILE | HA_OPEN_RNDFILE | HA_GET_INDEX;

/* the metadata lock the server's prelocking takes on a child it may cascade into.  anything weaker
   means the statement was not prelocked for this child, and opening it would race a DDL. */
static constexpr enum_mdl_type TDB_FK_CHILD_MDL = MDL_SHARED_WRITE;

tdb_fk_child_table::~tdb_fk_child_table()
{
    close();
}

TABLE *tdb_fk_child_table::open(THD *thd, const std::string &db, const std::string &tbl)
{
    if (!thd || db.empty() || tbl.empty() || share_) return nullptr;

    if (!thd->mdl_context.owns_equal_or_stronger_lock(MDL_key::TABLE, db.c_str(), tbl.c_str(),
                                                      TDB_FK_CHILD_MDL))
        return nullptr;

    /* the share cache is keyed by the database and table names, each with its terminator. */
    std::string key;
    key.reserve(db.size() + tbl.size() + 2);
    key.append(db).push_back('\0');
    key.append(tbl).push_back('\0');

    mysql_mutex_lock(&LOCK_open);
    TABLE_SHARE *share =
        get_table_share(thd, db.c_str(), tbl.c_str(), key.data(), key.size(), false);
    mysql_mutex_unlock(&LOCK_open);
    if (!share) return nullptr;
    share_ = share;
    thd_ = thd;

    if (share->is_view ||
        open_table_from_share(thd, share, tbl.c_str(), TDB_FK_CHILD_OPEN_FILES, EXTRA_RECORD,
                              thd->open_options, &table_, false, nullptr) != 0)
    {
        /* a failed open has already destroyed the handler but leaves the pointer behind. */
        table_.file = nullptr;
        close();
        return nullptr;
    }

    /* the handler joins the session's transaction the way any table the statement opened does. */
    table_.reginfo.lock_type = TL_WRITE;
    if (table_.file->ha_external_lock(thd, F_WRLCK) != 0)
    {
        (void)closefrm(&table_, false); /* the open failed; there is nothing to report past it */
        table_.file = nullptr;
        close();
        return nullptr;
    }
    locked_ = true;
    return &table_;
}

void tdb_fk_child_table::close()
{
    if (!share_) return;

    if (table_.file)
    {
        /* both results describe a table this cascade is finished with and the statement's own
           commit or rollback settles the rows, so there is no caller left to hand them to. */
        if (locked_) (void)table_.file->ha_external_lock(thd_, F_UNLCK);
        (void)closefrm(&table_, false);
        table_.file = nullptr;
    }
    locked_ = false;

    mysql_mutex_lock(&LOCK_open);
    release_table_share(share_);
    mysql_mutex_unlock(&LOCK_open);
    share_ = nullptr;
    thd_ = nullptr;
}
