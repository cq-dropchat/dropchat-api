import * as libsql from "@libsql/client";
import type { LibSQLConfig } from "../config.ts";
import type {
  ColumnCommentRow,
  ColumnRow,
  ConstraintRow,
  EnumRow,
  TableCommentRow,
  TableRow,
} from "../queries.ts";
import { BaseClient } from "./base.ts";

// LibSQL client implementation

export class LibSQLClient extends BaseClient {
  private conn: libsql.Client;

  constructor(config: LibSQLConfig) {
    super(config);

    this.conn = libsql.createClient({
      url: config.url,
      authToken: config.token,
    });
  }

  override async execute<T = Record<string, unknown>>(
    query: string,
    args?: unknown[],
  ): Promise<T[]> {
    const result = await this.conn.execute(query, args as libsql.InArgs);
    return result.rows as T[];
  }

  override async close() {
    return await this.conn.close();
  }

  override async tables() {
    return await this.execute<TableRow>(`
      SELECT schema, name, type
      FROM pragma_table_list
      WHERE name NOT LIKE 'sqlite_%'
      ORDER BY schema, name;
    `);
  }

  override async columns() {
    return await this.execute<ColumnRow>(`
      SELECT
        t.schema AS table_schema,
        t.name AS table_name,
        ti.name AS name,
        ti.type AS type,
        NOT(ti."notnull") as nullable,
        ti.dflt_value AS "default"
      FROM pragma_table_list AS t
      JOIN pragma_table_info(t.name, t.schema) AS ti
        ON 1
      WHERE t.name NOT LIKE 'sqlite_%'
      ORDER BY t.schema, t.name, ti.cid;
    `);
  }

  override async constraints() {
    const pk_and_unique = await this.execute<ConstraintRow>(`
      SELECT
        t.schema AS table_schema,
        t.name AS table_name,
        t.schema AS schema,
        il.name,
        CASE il.origin WHEN 'pk' THEN 'PRIMARY KEY' ELSE 'UNIQUE' END AS type,
        CASE ii.cid WHEN -1 THEN '(rowid)' ELSE ii.name END AS column_name,
        ii.seqno + 1 AS column_ordinal_position -- keep 1-indexed based on the SQL standard
      FROM pragma_table_list AS t
      JOIN pragma_index_list(t.name, t.schema) AS il
        ON 1
      LEFT JOIN pragma_index_info(il.name, t.schema) AS ii
        ON 1
      WHERE t.name NOT LIKE 'sqlite_%'
        AND il."unique" -- avoid partial indexes
        AND ii.cid >= -1 -- accept columns (>=0) and rowid (-1) but reject expression (-2)
      ORDER BY t.schema, t.name, il.name, ii.seqno;
    `);

    const fk = await this.execute<ConstraintRow>(`
      SELECT
        t.schema AS table_schema,
        t.name AS table_name,
        t.schema AS schema,
        CONCAT('fk', '_', t.name, '_', fk.id) AS name,
        "FOREIGN KEY" AS type,
        fk."from" AS column_name,
        fk.seq + 1 AS column_ordinal_position,
        t.schema AS referenced_constraint_schema,
        '' AS referenced_constraint_name,
        t.schema AS referenced_table_schema,
        fk."table" AS referenced_table_name,
        fk."to" AS referenced_column_name
      FROM pragma_table_list AS t
      JOIN pragma_foreign_key_list(t.name, t.schema) AS fk
        ON 1
      WHERE t.name NOT LIKE 'sqlite_%'
      ORDER BY t.schema, t.name, 4, fk.seq
    `);

    return [...pk_and_unique, ...fk];
  }

  override tableComments(): Promise<TableCommentRow[]> {
    return Promise.resolve([]);
  }

  override columnComments(): Promise<ColumnCommentRow[]> {
    return Promise.resolve([]);
  }

  override enums(): Promise<EnumRow[]> {
    return Promise.resolve([]);
  }
}
