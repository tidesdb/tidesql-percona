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

/* where a foreign key's definition comes from at CREATE and ALTER time, and how the parent's key
 * is addressed once it is resolved.
 *
 * MySQL 8.0 made foreign keys dictionary objects and stopped handing the parser's key list to the
 * engine.  the dictionary definition the server passes create() carries each constraint whole --
 * its name, referenced table, column pairs, referential actions, and the name of the parent key it
 * resolved the constraint against -- and that object has the same shape on every release the
 * engine builds against.  the share's own foreign_key array does not: before 9.6 it records
 * neither the constraint name nor the referenced columns.  so the engine reads the definition it
 * was handed, which is also what a copying ALTER hands create() for the new table.
 *
 * the one thing the server does not publish is the parent key's shape -- whether its parts carry a
 * null indicator -- because that is a fact about how the parent's keys were written rather than
 * about the constraint.  the engine records it in the parent's own index column family when that
 * family is created, and reads it back here.
 *
 * the engine persists and enforces its own copy of the constraint.  the dictionary stays
 * authoritative for what SHOW CREATE TABLE and information_schema report, which are the server's to
 * answer; the engine's catalog is what the row paths enforce against. */

#include "src/handler/ha_tidesdb_fk_source.h"

#include <cstring>

#include "dd/types/column.h"
#include "dd/types/foreign_key.h"
#include "dd/types/foreign_key_element.h"
#include "dd/types/table.h"
#include "sql_class.h"
#include "src/engine/ha_tidesdb_config.h"
#include "src/handler/ha_tidesdb_internal.h"

/* the referential actions, as the engine stores them.  the dictionary numbers its rules from one
   and orders them differently from the parser enum the catalog format was defined against, so the
   mapping is explicit rather than a cast -- getting it wrong would silently turn a RESTRICT into a
   CASCADE on the next delete.  the enum itself is a plain declaration out of a header the server's
   own table.h already includes, so naming it costs no dictionary dependency. */
static uint8 tdb_rule_to_fk_option(dd::Foreign_key::enum_rule rule)
{
    switch (rule)
    {
        case dd::Foreign_key::RULE_RESTRICT:
            return (uint8)FK_OPTION_RESTRICT;
        case dd::Foreign_key::RULE_CASCADE:
            return (uint8)FK_OPTION_CASCADE;
        case dd::Foreign_key::RULE_SET_NULL:
            return (uint8)FK_OPTION_SET_NULL;
        case dd::Foreign_key::RULE_SET_DEFAULT:
            return (uint8)FK_OPTION_DEFAULT;
        case dd::Foreign_key::RULE_NO_ACTION:
            return (uint8)FK_OPTION_NO_ACTION;
    }
    return (uint8)FK_OPTION_UNDEF;
}

bool tdb_fk_extract_specs(const dd::Table *table_def, std::vector<tdb_fk_spec> &out)
{
    out.clear();

    /* A table created without any foreign key still reaches here, which is not an error. */
    if (!table_def) return true;

    for (const dd::Foreign_key *fk : table_def->foreign_keys())
    {
        tdb_fk_spec spec;
        spec.name.assign(fk->name().c_str(), fk->name().length());
        spec.on_delete = tdb_rule_to_fk_option(fk->delete_rule());
        spec.on_update = tdb_rule_to_fk_option(fk->update_rule());

        spec.ref_db.assign(fk->referenced_table_schema_name().c_str(),
                           fk->referenced_table_schema_name().length());
        spec.ref_table.assign(fk->referenced_table_name().c_str(),
                              fk->referenced_table_name().length());

        /* The column pairs, in the constraint's declared order, which is the order the engine's
           catalog format and its key encoding both assume. */
        for (const dd::Foreign_key_element *e : fk->elements())
        {
            spec.child_columns.emplace_back(e->column().name().c_str(),
                                            e->column().name().length());
            spec.ref_columns.emplace_back(e->referenced_column_name().c_str(),
                                          e->referenced_column_name().length());
        }

        /* The server resolved which of the parent's keys the constraint matches and recorded its
           name here, leaving it empty when the parent key is neither primary nor unique. */
        spec.parent_index_name.assign(fk->unique_constraint_name().c_str(),
                                      fk->unique_constraint_name().length());

        out.push_back(std::move(spec));
    }
    return true;
}

bool tdb_fk_parent_key_shape(const std::string &parent_cf, const std::string &parent_index_name,
                             std::vector<uint8> &out)
{
    out.clear();
    if (parent_cf.empty() || parent_index_name.empty()) return false;

    tidesdb_column_family_t *cf = tidesdb_get_column_family(tdb_global, parent_cf.c_str());
    if (!cf) return false;

    return tdb_key_shape_load(cf, parent_index_name, &out);
}
