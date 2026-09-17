import type { Driver } from "./config.ts";

// Query builders

export type TableRow = {
  schema: string;
  name: string;
  type: string;
};

export function getTablesQuery(quotedSchemas: string) {
  return `
    SELECT
      t.table_schema AS schema,
      t.table_name AS name,
      t.table_type AS type
    FROM information_schema.tables t
    WHERE t.table_schema IN (${quotedSchemas})
    ORDER BY t.table_schema, t.table_name;
  `;
}

export type ColumnRow = {
  table_schema: string;
  table_name: string;
  name: string;
  type: string;
  nullable: boolean;
  default: string | null;
};

export function getColumnsQuery(quotedSchemas: string, driver: Driver) {
  let typeColumn = "";
  // `default` is a reserved word; each driver quotes the alias its own way
  // (backticks were a syntax error in Postgres).
  let defaultAlias = "";

  if (driver === "postgres") {
    typeColumn = "udt_name";
    defaultAlias = '"default"';
  } else if (driver === "mysql") {
    typeColumn = "column_type";
    defaultAlias = "`default`";
  }

  return `
    SELECT
      c.table_schema,
      c.table_name,
      c.column_name AS name,
      c.${typeColumn} AS type,
      c.is_nullable = 'YES' AS nullable,
      c.column_default AS ${defaultAlias}
    FROM information_schema.columns c
    WHERE c.table_schema IN (${quotedSchemas})
    ORDER BY c.table_schema, c.table_name, c.ordinal_position;
  `;
}

export type ConstraintRow =
  | {
    table_schema: string;
    table_name: string;
    schema: string;
    name: string;
    type: "PRIMARY KEY" | "UNIQUE";
    column_name: string;
    column_ordinal_position: number;
  }
  | {
    table_schema: string;
    table_name: string;
    schema: string;
    name: string;
    type: "FOREIGN KEY";
    column_name: string;
    column_ordinal_position: number;
    referenced_constraint_schema: string;
    referenced_constraint_name: string;
    referenced_table_schema: string;
    referenced_table_name: string;
    referenced_column_name: string;
  };

export function getPostgresConstraintsQuery(quotedSchemas: string) {
  return `
    SELECT
      tc.table_schema,
      tc.table_name,
      tc.constraint_schema AS schema,
      tc.constraint_name   AS name,
      tc.constraint_type   AS type,
      kcu.column_name,
      kcu.ordinal_position AS column_ordinal_position,
      rc.unique_constraint_schema AS referenced_constraint_schema,
      rc.unique_constraint_name   AS referenced_constraint_name,
      rkcu.table_schema AS referenced_table_schema,
      rkcu.table_name   AS referenced_table_name,
      rkcu.column_name  AS referenced_column_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON tc.constraint_schema = kcu.constraint_schema
     AND tc.constraint_name   = kcu.constraint_name
    LEFT JOIN information_schema.referential_constraints rc
      ON tc.constraint_schema = rc.constraint_schema
     AND tc.constraint_name   = rc.constraint_name
    -- The referenced column of each key column, by its position in the
    -- referenced key. (constraint_column_usage has one row per column of
    -- the constraint, unpaired: joining it repeated every column of a
    -- multi-column key once per column.)
    LEFT JOIN information_schema.key_column_usage rkcu
      ON rkcu.constraint_schema = rc.unique_constraint_schema
     AND rkcu.constraint_name   = rc.unique_constraint_name
     AND rkcu.ordinal_position  = kcu.position_in_unique_constraint
    WHERE tc.table_schema IN (${quotedSchemas})
      AND tc.constraint_type IN ('PRIMARY KEY', 'UNIQUE', 'FOREIGN KEY')
    ORDER BY
      tc.table_schema,
      tc.table_name,
      tc.constraint_schema,
      tc.constraint_name,
      kcu.ordinal_position;
  `;
}

export function getMySQLConstraintsQuery(_quotedSchemas: string) {
  return `
    SELECT
      tc.table_schema,
      tc.table_name,
      tc.constraint_schema AS schema,
      tc.constraint_name   AS name,
      tc.constraint_type   AS type,
      kcu.column_name,
      kcu.ordinal_position AS column_ordinal_position,
      rc.unique_constraint_schema AS referenced_constraint_schema,
      rc.unique_constraint_name   AS referenced_constraint_name,
      kcu.referenced_table_schema,
      kcu.referenced_table_name,
      kcu.referenced_column_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON tc.constraint_name = kcu.constraint_name
     AND tc.table_name      = kcu.table_name
    LEFT JOIN information_schema.referential_constraints rc
      ON tc.constraint_name = rc.constraint_name
     AND tc.table_name      = rc.table_name
    WHERE tc.constraint_type IN ('PRIMARY KEY', 'UNIQUE', 'FOREIGN KEY')
    ORDER BY
      tc.table_schema,
      tc.table_name,
      tc.constraint_schema,
      tc.constraint_name,
      kcu.ordinal_position;
  `;
}

export type TableCommentRow = {
  schema: string;
  name: string;
  comment: string;
};

export function getPostgresTableCommentsQuery(quotedSchemas: string) {
  return `
      SELECT
        n.nspname AS schema,
        c.relname AS name,
        d.description AS comment
      FROM pg_class c
      JOIN pg_namespace n
        ON n.oid = c.relnamespace
      LEFT JOIN pg_description d
        ON d.objoid = c.oid
       AND d.classoid = 'pg_class'::regclass
       AND d.objsubid = 0 -- the table itself; its columns have objsubid > 0
      WHERE c.relkind = 'r' AND n.nspname IN (${quotedSchemas})
        AND d.description IS NOT NULL
      ORDER BY n.nspname, c.relname;
    `;
}

export function getMySQLTableCommentsQuery(_quotedSchemas: string) {
  return `
      SELECT
        t.table_schema AS schema,
        t.table_name AS name,
        t.table_comment AS comment
      FROM information_schema.tables t
      WHERE t.table_comment IS NOT NULL
      ORDER BY t.table_schema, t.table_name;
    `;
}

export type ColumnCommentRow = {
  table_schema: string;
  table_name: string;
  name: string;
  comment: string;
};

export function getPostgresColumnCommentsQuery(quotedSchemas: string) {
  return `
      SELECT
        n.nspname AS table_schema,
        c.relname AS table_name,
        a.attname AS name,
        d.description AS comment
      FROM pg_attribute a
      JOIN pg_class c
        ON c.oid = a.attrelid
      JOIN pg_namespace n
        ON n.oid = c.relnamespace
      LEFT JOIN pg_description d
        ON d.objoid = a.attrelid
       AND d.objsubid = a.attnum
      WHERE a.attnum > 0
        AND NOT a.attisdropped
        AND n.nspname IN (${quotedSchemas})
        AND d.description IS NOT NULL
      ORDER BY n.nspname, c.relname, a.attnum;
    `;
}

export function getMySQLColumnCommentsQuery(_quotedSchemas: string) {
  return `
      SELECT
        c.table_schema,
        c.table_name,
        c.column_name AS name,
        c.column_comment AS comment
      FROM information_schema.columns c
      WHERE c.column_comment IS NOT NULL
      ORDER BY c.table_schema, c.table_name, c.ordinal_position;
    `;
}

export type EnumRow = {
  schema: string;
  name: string;
  values: string[];
};

export function getPostgresEnumsQuery(quotedSchemas: string) {
  return `
      SELECT
        n.nspname AS schema,
        t.typname AS name,
        array_agg(e.enumlabel ORDER BY e.enumsortorder) AS values
      FROM pg_type t
      JOIN pg_enum e
        ON t.oid = e.enumtypid
      JOIN pg_namespace n
        ON n.oid = t.typnamespace
      WHERE n.nspname IN (${quotedSchemas})
      GROUP BY n.nspname, t.typname
      ORDER BY n.nspname, t.typname;
    `;
}
