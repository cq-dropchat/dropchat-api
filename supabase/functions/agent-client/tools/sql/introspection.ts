import type { ConstraintDef, DBSchema, TableDef } from "./config.ts";
import type { BaseClient } from "./clients/base.ts";

export async function getDbSchema(client: BaseClient): Promise<DBSchema> {
  // Fetch all pieces in parallel
  const [
    tableRows,
    columnRows,
    constraintRows,
    tableCommentRows,
    columnCommentRows,
    enumRows,
  ] = await Promise.all([
    client.tables(),
    client.columns(),
    client.constraints(),
    client.tableComments(),
    client.columnComments(),
    client.enums(),
  ]);

  // -----------------------------------------------------------------------
  //  Tables
  // -----------------------------------------------------------------------

  // Map to store table definitions keyed by "schema.name"
  const tableMap = new Map<string, TableDef>();

  // Pre-populate tables map
  for (const t of tableRows) {
    const key = `${t.schema}.${t.name}`;
    tableMap.set(key, {
      schema: t.schema,
      name: t.name,
      type: t.type,
      columns: [],
      constraints: [],
      comment: undefined,
    });
  }

  // -----------------------------------------------------------------------
  //  Table & column comments
  // -----------------------------------------------------------------------

  // Table comments
  for (const tc of tableCommentRows) {
    const key = `${tc.schema}.${tc.name}`;
    const table = tableMap.get(key);

    if (table && tc.comment) {
      table.comment = tc.comment;
    }
  }

  // Build a quick lookup map for column comments
  const columnCommentMap = new Map<string, string>();
  for (const cc of columnCommentRows) {
    columnCommentMap.set(
      `${cc.table_schema}.${cc.table_name}.${cc.name}`,
      cc.comment,
    );
  }

  // -----------------------------------------------------------------------
  //  Columns
  // -----------------------------------------------------------------------

  for (const c of columnRows) {
    const tableKey = `${c.table_schema}.${c.table_name}`;
    const table = tableMap.get(tableKey);
    if (!table) continue; // should not happen but just in case

    const comment = columnCommentMap.get(
      `${c.table_schema}.${c.table_name}.${c.name}`,
    );

    table.columns.push({
      name: c.name,
      type: c.type,
      nullable: Boolean(c.nullable),
      ...(c.default && { default: c.default }),
      ...(comment && { comment }),
    });
  }

  // -----------------------------------------------------------------------
  //  Constraints
  // -----------------------------------------------------------------------

  const constraintMap = new Map<string, ConstraintDef>();

  for (const constraintColumn of constraintRows) {
    const key = [
      constraintColumn.table_schema,
      constraintColumn.table_name,
      constraintColumn.schema,
      constraintColumn.name,
    ].join(".");

    let constraint = constraintMap.get(key);

    if (!constraint) {
      if (constraintColumn.type === "FOREIGN KEY") {
        constraint = {
          schema: constraintColumn.schema,
          name: constraintColumn.name,
          type: "FOREIGN KEY",
          columns: [],
          referenced_constraint: {
            schema: constraintColumn.referenced_constraint_schema,
            name: constraintColumn.referenced_constraint_name,
          },
          referenced_table: {
            schema: constraintColumn.referenced_table_schema,
            name: constraintColumn.referenced_table_name,
            columns: [],
          },
        };
      } else {
        constraint = {
          schema: constraintColumn.schema,
          name: constraintColumn.name,
          type: constraintColumn.type as "PRIMARY KEY" | "UNIQUE",
          columns: [],
        };
      }

      constraintMap.set(key, constraint);

      const tableKey =
        `${constraintColumn.table_schema}.${constraintColumn.table_name}`;
      const table = tableMap.get(tableKey);
      if (!table) continue; // should not happen but just in case

      table.constraints.push(constraint);
    }

    constraint.columns.push(constraintColumn.column_name);

    if (
      constraint.type === "FOREIGN KEY" &&
      constraintColumn.type === "FOREIGN KEY"
    ) {
      constraint.referenced_table.columns.push(
        constraintColumn.referenced_column_name,
      );
    }
  }

  // -----------------------------------------------------------------------
  //  DB Schema
  // -----------------------------------------------------------------------

  const result: DBSchema = {
    sql_dialect: client.driver === "libsql" ? "sqlite" : client.driver,
    tables: Array.from(tableMap.values()),
  };

  if (enumRows && enumRows.length) {
    result.enums = enumRows;
  }

  return result;
}
