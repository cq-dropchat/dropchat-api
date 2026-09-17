import type { LocalSQLToolConfig } from "../../../../_shared/supabase.ts";
import type { Driver } from "../config.ts";
import {
  type ColumnCommentRow,
  type ColumnRow,
  type ConstraintRow,
  type EnumRow,
  getColumnsQuery,
  getTablesQuery,
  type TableCommentRow,
  type TableRow,
} from "../queries.ts";

// F08: connection and statement limits for every driver.
export const CONNECT_TIMEOUT_SECONDS = 3;
export const STATEMENT_TIMEOUT_MS = 5_000;

// Database client

export class BaseClient {
  driver: Driver;
  quotedSchemas: string = "";

  private getQuotedSchemas(schemas: string[]): string {
    return schemas.map((s) => `'${s.replace(/'/g, "''")}'`).join(", ");
  }

  setSchemas(schemas?: string[]) {
    if (this.driver === "postgres") {
      if (!schemas || schemas.length === 0) {
        schemas = ["public"];
      }

      this.quotedSchemas = this.getQuotedSchemas(schemas!);
    } else if (this.driver === "mysql") {
      this.quotedSchemas = "DATABASE()";
    }
  }

  constructor(config: LocalSQLToolConfig["config"]) {
    this.driver = config.driver;

    this.setSchemas();
  }

  execute<T = Record<string, unknown>>(
    _query: string,
    _args?: unknown[],
  ): Promise<T[]> {
    return Promise.reject(new Error("Not implemented"));
  }

  close(): Promise<void> {
    return Promise.reject(new Error("Not implemented"));
  }

  async tables() {
    return await this.execute<TableRow>(getTablesQuery(this.quotedSchemas));
  }

  async columns() {
    return await this.execute<ColumnRow>(
      getColumnsQuery(this.quotedSchemas, this.driver!),
    );
  }

  constraints(): Promise<ConstraintRow[]> {
    return Promise.reject(new Error("Not implemented"));
  }

  tableComments(): Promise<TableCommentRow[]> {
    return Promise.reject(new Error("Not implemented"));
  }

  columnComments(): Promise<ColumnCommentRow[]> {
    return Promise.reject(new Error("Not implemented"));
  }

  enums(): Promise<EnumRow[]> {
    return Promise.reject(new Error("Not implemented"));
  }

  /** The bind parameter at 0-based `index`: `?` unless the driver differs. */
  placeholder(_index: number): string {
    return "?";
  }

  quoteIdentifier(identifier: string): string {
    return '"' + identifier + '"';
  }

  sanitizeIdentifier(identifier: string): string {
    return (
      identifier
        .trim()
        .toLowerCase()
        // allow letters (including accents), digits, and underscore
        .replace(/[^\p{L}\p{N}_]+/gu, "_") // \p{L} = any kind of letter, \p{N} = any kind of digit
    );
  }
}
