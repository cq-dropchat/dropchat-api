import mysql from "mysql2";
import type { SQLConfig } from "../config.ts";
import {
  type ColumnCommentRow,
  type ConstraintRow,
  type EnumRow,
  getMySQLColumnCommentsQuery,
  getMySQLConstraintsQuery,
  getMySQLTableCommentsQuery,
  type TableCommentRow,
} from "../queries.ts";
import {
  BaseClient,
  CONNECT_TIMEOUT_SECONDS,
  STATEMENT_TIMEOUT_MS,
} from "./base.ts";

// MySQL client implementation

export class MySQLClient extends BaseClient {
  private conn: Promise<mysql.Connection>;

  constructor(config: SQLConfig) {
    super(config);

    this.conn = mysql.createConnection({
      host: config.host,
      port: config.port,
      user: config.user,
      database: config.database,
      password: config.password,
      connectTimeout: CONNECT_TIMEOUT_SECONDS * 1000,
    });
  }

  override async execute<T = Record<string, unknown>>(
    query: string,
    args?: unknown[],
  ): Promise<T[]> {
    // @ts-ignore Connection does have a query method
    const [results, _fields] = await (await this.conn).query(
      { sql: query, timeout: STATEMENT_TIMEOUT_MS },
      args,
    );
    return results as T[];
  }

  override async close() {
    return await (await this.conn).end();
  }

  override async constraints(): Promise<ConstraintRow[]> {
    return await this.execute<ConstraintRow>(
      getMySQLConstraintsQuery(this.quotedSchemas),
    );
  }

  override async tableComments(): Promise<TableCommentRow[]> {
    return await this.execute<TableCommentRow>(
      getMySQLTableCommentsQuery(this.quotedSchemas),
    );
  }

  override async columnComments(): Promise<ColumnCommentRow[]> {
    return await this.execute<ColumnCommentRow>(
      getMySQLColumnCommentsQuery(this.quotedSchemas),
    );
  }

  override enums(): Promise<EnumRow[]> {
    return Promise.resolve([]);
  }

  override quoteIdentifier(identifier: string): string {
    return "`" + identifier + "`";
  }
}
