import * as z from "zod";

// Type definitions
export type Driver = "postgres" | "mysql" | "libsql";

export type DBSchema = {
  sql_dialect: "postgres" | "mysql" | "sqlite";
  enums?: EnumDef[]; // PostgreSQL only
  tables: TableDef[];
};

export type EnumDef = {
  schema: string;
  name: string;
  values: string[];
};

export type TableDef = {
  schema: string;
  name: string;
  type: string;
  columns: ColumnDef[];
  constraints: ConstraintDef[];
  comment?: string;
};

export type ColumnDef = {
  name: string;
  type: string; // use udt_name
  nullable: boolean;
  default?: string;
  comment?: string;
};

export type ConstraintDef = UniqueConstraintDef | ForeignKeyConstraintDef;

export type UniqueConstraintDef = {
  schema: string;
  name: string;
  type: "PRIMARY KEY" | "UNIQUE";
  columns: string[]; // sorted by ordinal_position
};

export type ForeignKeyConstraintDef = {
  schema: string;
  name: string;
  type: "FOREIGN KEY";
  columns: string[]; // sorted by ordinal_position
  referenced_table: {
    schema: string;
    name: string;
    columns: string[]; // sorted by position_in_unique_constraint
  };
  referenced_constraint: {
    schema: string;
    name: string;
  };
};

// Schema definitions

export const LibSQLConfigSchema = z.object({
  driver: z.literal("libsql"),
  url: z.string(),
  token: z.string().optional(),
});
export type LibSQLConfig = z.infer<typeof LibSQLConfigSchema>;

export const SQLConfigSchema = z.object({
  driver: z.union([z.literal("postgres"), z.literal("mysql")]),
  host: z.string(),
  port: z.number().optional(),
  user: z.string().optional(),
  password: z.string().optional(),
  database: z.string().optional(),
});
export type SQLConfig = z.infer<typeof SQLConfigSchema>;

export type SQLToolConfig = LibSQLConfig | SQLConfig;

export const GetDbSchemaInputSchema = z.object({
  schemas: z
    .array(z.string())
    .optional()
    .describe("Optional: schema names to include."),
});

export const GetDbSchemaOutputSchema = z.object({
  enums: z
    .array(
      z.object({
        schema: z.string(),
        name: z.string(),
        values: z.array(z.string()),
      }),
    )
    .optional(),
  tables: z.array(
    z.object({
      schema: z.string(),
      name: z.string(),
      type: z.string(),
      columns: z.array(
        z.object({
          name: z.string(),
          type: z.string(),
          nullable: z.boolean(),
          default: z.string().optional(),
          comment: z.string().optional(),
        }),
      ),
      constraints: z.array(
        z.union([
          z.object({
            schema: z.string(),
            name: z.string(),
            type: z.union([z.literal("PRIMARY KEY"), z.literal("UNIQUE")]),
            columns: z.array(z.string()),
          }),
          z.object({
            schema: z.string(),
            name: z.string(),
            type: z.literal("FOREIGN KEY"),
            columns: z.array(z.string()),
            referenced_table: z.object({
              schema: z.string(),
              name: z.string(),
              columns: z.array(z.string()),
            }),
            referenced_constraint: z.object({
              schema: z.string(),
              name: z.string(),
            }),
          }),
        ]),
      ),
      comment: z.string().optional(),
    }),
  ),
});
