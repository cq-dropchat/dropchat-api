import postgres from "postgres";
import type { SQLConfig } from "../config.ts";
import {
  type ColumnCommentRow,
  type ConstraintRow,
  type EnumRow,
  getPostgresColumnCommentsQuery,
  getPostgresConstraintsQuery,
  getPostgresEnumsQuery,
  getPostgresTableCommentsQuery,
  type TableCommentRow,
} from "../queries.ts";
import {
  BaseClient,
  CONNECT_TIMEOUT_SECONDS,
  STATEMENT_TIMEOUT_MS,
} from "./base.ts";

// Postgres client implementation

export class PostgresClient extends BaseClient {
  private conn: postgres.Sql;

  constructor(config: SQLConfig) {
    super(config);

    const connectionConfig = {
      host: config.host,
      port: config.port,
      user: config.user,
      password: config.password,
      database: config.database,
      connect_timeout: CONNECT_TIMEOUT_SECONDS,
      // Sent as a startup parameter: every statement on the session is cut
      // at the limit, whatever the query says.
      connection: { statement_timeout: STATEMENT_TIMEOUT_MS },
      max: 1,
    };
    this.conn = postgres(connectionConfig);
  }

  override async execute<T = Record<string, unknown>>(
    query: string,
    args?: unknown[],
  ): Promise<T[]> {
    return await this.conn.unsafe(
      query,
      args as postgres.ParameterOrJSON<never>[],
    );
  }

  override async close() {
    return await this.conn.end();
  }

  override async constraints(): Promise<ConstraintRow[]> {
    return await this.execute<ConstraintRow>(
      getPostgresConstraintsQuery(this.quotedSchemas),
    );
  }

  override async tableComments(): Promise<TableCommentRow[]> {
    return await this.execute<TableCommentRow>(
      getPostgresTableCommentsQuery(this.quotedSchemas),
    );
  }

  override async columnComments(): Promise<ColumnCommentRow[]> {
    return await this.execute<ColumnCommentRow>(
      getPostgresColumnCommentsQuery(this.quotedSchemas),
    );
  }

  override async enums(): Promise<EnumRow[]> {
    return await this.execute<EnumRow>(
      getPostgresEnumsQuery(this.quotedSchemas),
    );
  }
}
