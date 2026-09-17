/**
 * SQL tool
 *
 * {
 *   "provider": "local",
 *   "type": "sql",
 *   "database_label": "my_database",
 *   "driver": "postgres",
 *   "host": "localhost",
 *   "username": "my_user",
 * }
 *
 * This tool inherits from the base SQL tool. It makes tools based on SQL queries.
 * Instead of accepting a raw SQL query, it accepts parameters.
 *
 * Functions has access to the context object internally. References to the context object such as
 * the organization address could be expressed as "$context.conversation.organization_address" in the SQL query.
 *
 * {
 *   "database_label": "my_database", // DB config to use
 *   "name": "get_user_by_organization_address",
 *   "description": "Get a user by organization address",
 *   "input": {
 *     "type": "object",
 *     "properties": {
 *       "name": {
 *         "type": "string",
 *         "description": "The name of the user"
 *       }
 *     },
 *     "required": ["name"]
 *   }, // Will be used as JSON schema for the tool input.
 *   "query": "
 *     SELECT * FROM users
 *     WHERE organization_address = '$context.conversation.organization_address'
 *     AND name = '$input.name'
 *   "
 * }
 */
//
// F29: split from one 1,337-line file. The tools and their implementations
// stay here; the rest lives in sql/:
//   sql/config.ts          connection config and schema output types
//   sql/queries.ts         introspection queries per driver
//   sql/clients/*.ts       one client per driver, and the guarded factory
//   sql/introspection.ts   rows → DBSchema

import * as z from "zod";
import { parse } from "jsr:@std/csv/parse";
import { stringify } from "jsr:@std/csv/stringify";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { RequestContext } from "../protocols/base.ts";
import type { ToolDefinition } from "./base.ts";
import { downloadFromStorage, uploadToStorage } from "../../_shared/media.ts";
import {
  GetDbSchemaInputSchema,
  GetDbSchemaOutputSchema,
  type SQLToolConfig,
} from "./sql/config.ts";
import { createDBClient } from "./sql/clients/index.ts";
import { getDbSchema } from "./sql/introspection.ts";

export {
  GetDbSchemaInputSchema,
  GetDbSchemaOutputSchema,
  LibSQLConfigSchema,
  SQLConfigSchema,
  type SQLToolConfig,
} from "./sql/config.ts";

export async function getDbSchemaImplementation(
  input: z.infer<typeof GetDbSchemaInputSchema>,
  config: SQLToolConfig,
  _context: RequestContext,
): Promise<z.infer<typeof GetDbSchemaOutputSchema>> {
  const client = await createDBClient(config);

  client.setSchemas(input.schemas);

  try {
    return await getDbSchema(client);
  } finally {
    await client.close();
  }
}

// -----------------------------------------------------------------------
//  Execute SQL
// -----------------------------------------------------------------------

export const ExecuteSqlInputSchema = z.object({
  query: z.string().describe("The SQL query to execute."),
});

export const ExecuteSqlOutputSchema = z.array(z.record(z.string(), z.any()));

export async function executeSqlImplementation(
  input: z.infer<typeof ExecuteSqlInputSchema>,
  config: SQLToolConfig,
  _context: RequestContext,
): Promise<z.infer<typeof ExecuteSqlOutputSchema>> {
  const client = await createDBClient(config);

  try {
    return await client.execute(input.query);
  } finally {
    await client.close();
  }
}

// -----------------------------------------------------------------------
//  Bulk insert
// -----------------------------------------------------------------------

const BulkInsertInputSchema = z.object({
  schema: z.string().optional().describe("The schema to insert into."),
  table: z
    .string()
    .describe(
      "The table to insert into. It will be created if it does not exist. Use the 'temp_' prefix if the table should be deleted later.",
    ),
  columns: z
    .array(z.string())
    .optional()
    .describe(
      "Subset of columns to read from the CSV file. If not provided, all columns are used.",
    ),
  types: z
    .array(z.string())
    .optional()
    .describe(
      "Types of columns, when the table has to be created. If not provided, TEXT is used for all columns.",
    ),
  renames: z
    .array(z.object({ from: z.string(), to: z.string() }))
    .optional()
    .describe(
      "Renames columns using a mapper. Columns not in the mapper are left as-is.",
    ),
  file_uri: z.string().describe("The URI of the CSV file to insert."),
});

const BulkInsertOutputSchema = z.object({
  columns: z.array(z.string()),
  rows_inserted: z.number(),
});

export async function bulkInsertImplementation(
  input: z.infer<typeof BulkInsertInputSchema>,
  config: SQLToolConfig,
  _context: RequestContext,
  supabaseClient: SupabaseClient,
): Promise<z.infer<typeof BulkInsertOutputSchema>> {
  const client = await createDBClient(config);

  const file = await downloadFromStorage(supabaseClient, input.file_uri);

  const text = await file.text();

  const csv = parse(text, { skipFirstRow: true });

  if (!csv.length) {
    return {
      columns: [],
      rows_inserted: 0,
    };
  }

  const csvColumns = Object.keys(csv[0]);

  const source: string[] = [];

  for (const col of input.columns || []) {
    if (!csvColumns.includes(col)) {
      throw new Error(`Column ${col} declared in 'columns' not found in CSV`);
    }

    source.push(col);
  }

  if (!source.length) {
    source.push(...csvColumns);
  }

  if (input.types && input.types.length !== source.length) {
    throw new Error(
      `Number of types in 'types' must match the number of columns in 'columns' or the number of columns in the CSV file`,
    );
  }

  const target: string[] = [];

  for (const col of input.renames?.map((r) => r.from) || []) {
    if (!csvColumns.includes(col)) {
      throw new Error(
        `From column ${col} declared in 'renames' not found in CSV`,
      );
    }
  }

  for (const col of source) {
    // If the target column name comes from input.renames, use the renamed name as-is.
    // If it is taken from the CSV, sanitize the name.
    const targetCol = input.renames?.find((r) => r.from === col)?.to ||
      client.sanitizeIdentifier(col);

    // Deno's parse CSV implementation uses "" for empty column names.
    // It also does not distiguish between repeated column names.
    target.push(targetCol || "unnamed");
  }

  const table = [input.schema, input.table]
    .filter(Boolean)
    .map((s) => client.quoteIdentifier(s!))
    .join(".");

  const createQuery = `
    CREATE TABLE IF NOT EXISTS ${table} (
      ${
    target
      .map(
        (col, i) =>
          `${client.quoteIdentifier(col)} ${input.types?.[i] || "TEXT"}`,
      )
      .join(",\n      ")
  }
    );
  `;

  const values = csv.map((row) => source.map((col) => row[col] || null));

  const insertQuery = `
    INSERT INTO ${table} (${target.map(client.quoteIdentifier).join(", ")})
    VALUES
      ${
    csv
      .map((_row) => "(" + source.map((_col) => "?").join(", ") + ")")
      .join(",\n      ")
  }
    ;
  `;

  try {
    await client.execute(createQuery);
    await client.execute(insertQuery, values.flat());

    return {
      columns: target,
      rows_inserted: csv.length,
    };
  } finally {
    await client.close();
  }
}

// -----------------------------------------------------------------------
//  Select as CSV
// -----------------------------------------------------------------------

const SelectAsCsvInputSchema = z.object({
  query: z.string().describe("The SQL query to execute."),
  file_name: z.string().describe("The file name to use for the CSV file."),
});

const SelectAsCsvOutputSchema = z.object({
  file_uri: z.string().nullable(),
  columns: z.array(z.string()),
  rows_selected: z.number(),
});

export async function selectAsCsvImplementation(
  input: z.infer<typeof SelectAsCsvInputSchema>,
  config: SQLToolConfig,
  context: RequestContext,
  supabaseClient: SupabaseClient,
): Promise<z.infer<typeof SelectAsCsvOutputSchema>> {
  const client = await createDBClient(config);

  try {
    const result = await client.execute(input.query);

    if (!result.length) {
      return {
        file_uri: null,
        columns: [],
        rows_selected: 0,
      };
    }

    const columns = Object.keys(result[0] as Record<string, string>);

    const text = stringify(result, { columns });

    const file = new Blob([text], { type: "text/csv" });

    return {
      file_uri: await uploadToStorage(
        supabaseClient,
        context.organization.id,
        file,
        input.file_name,
      ),
      columns,
      rows_selected: result.length,
    };
  } finally {
    await client.close();
  }
}

// -----------------------------------------------------------------------
//  Tools definitions
// -----------------------------------------------------------------------

export const GetDbSchemaTool: ToolDefinition<
  typeof GetDbSchemaInputSchema,
  typeof GetDbSchemaOutputSchema,
  SQLToolConfig
> = {
  provider: "local",
  type: "sql",
  name: "getDbSchema",
  description:
    "Get database schema information including tables, columns, constraints, and enums.",
  inputSchema: z.toJSONSchema(GetDbSchemaInputSchema),
  outputSchema: z.toJSONSchema(GetDbSchemaOutputSchema),
  implementation: getDbSchemaImplementation,
};

export const ExecuteSqlTool: ToolDefinition<
  typeof ExecuteSqlInputSchema,
  typeof ExecuteSqlOutputSchema,
  SQLToolConfig
> = {
  provider: "local",
  type: "sql",
  name: "executeSql",
  description: "Execute SQL queries against a SQL database.",
  inputSchema: z.toJSONSchema(ExecuteSqlInputSchema),
  outputSchema: z.toJSONSchema(ExecuteSqlOutputSchema),
  implementation: executeSqlImplementation,
};

export const BulkInsertTool: ToolDefinition<
  typeof BulkInsertInputSchema,
  typeof BulkInsertOutputSchema,
  SQLToolConfig
> = {
  provider: "local",
  type: "sql",
  name: "bulkInsert",
  description: "Bulk insert data into a SQL database from a CSV file URI.",
  inputSchema: z.toJSONSchema(BulkInsertInputSchema),
  outputSchema: z.toJSONSchema(BulkInsertOutputSchema),
  implementation: bulkInsertImplementation,
};

export const SelectAsCsvTool: ToolDefinition<
  typeof SelectAsCsvInputSchema,
  typeof SelectAsCsvOutputSchema,
  SQLToolConfig
> = {
  provider: "local",
  type: "sql",
  name: "selectAsCsv",
  description:
    "Select data from a SQL database and return it as a CSV file URI.",
  inputSchema: z.toJSONSchema(SelectAsCsvInputSchema),
  outputSchema: z.toJSONSchema(SelectAsCsvOutputSchema),
  implementation: selectAsCsvImplementation,
};

// -----------------------------------------------------------------------
//  Sample Table Rows
// -----------------------------------------------------------------------

const SampleTableRowsInputSchema = z.object({
  schemas: z
    .array(z.string())
    .optional()
    .describe("Optional: schema names to include."),
  limit: z
    .number()
    .min(1)
    .max(10)
    .default(3)
    .describe(
      "Number of rows to sample from each table (default: 3, max: 10).",
    ),
});

const SampleTableRowsOutputSchema = z.object({
  tables: z.array(
    z.object({
      schema: z.string(),
      name: z.string(),
      rows: z.array(z.record(z.string(), z.any())),
    }),
  ),
});

export async function sampleTableRowsImplementation(
  input: z.infer<typeof SampleTableRowsInputSchema>,
  config: SQLToolConfig,
  _context: RequestContext,
): Promise<z.infer<typeof SampleTableRowsOutputSchema>> {
  const client = await createDBClient(config);

  client.setSchemas(input.schemas);

  try {
    const tableRows = await client.tables();

    const result: z.infer<typeof SampleTableRowsOutputSchema> = {
      tables: [],
    };

    for (const table of tableRows) {
      const fullTableName = [table.schema, table.name]
        .map((s) => client.quoteIdentifier(s))
        .join(".");

      const sampleQuery = `SELECT * FROM ${fullTableName} LIMIT ${input.limit}`;

      const rows = await client.execute(sampleQuery);

      result.tables.push({
        schema: table.schema,
        name: table.name,
        rows,
      });
    }

    return result;
  } finally {
    await client.close();
  }
}

export const SampleTableRowsTool: ToolDefinition<
  typeof SampleTableRowsInputSchema,
  typeof SampleTableRowsOutputSchema,
  SQLToolConfig
> = {
  provider: "local",
  type: "sql",
  name: "sampleTableRows",
  description:
    "Sample N rows from each table in the database to preview actual data.",
  inputSchema: z.toJSONSchema(SampleTableRowsInputSchema),
  outputSchema: z.toJSONSchema(SampleTableRowsOutputSchema),
  implementation: sampleTableRowsImplementation,
};

export const SQLTools = [
  GetDbSchemaTool,
  ExecuteSqlTool,
  BulkInsertTool,
  SelectAsCsvTool,
  SampleTableRowsTool,
];
