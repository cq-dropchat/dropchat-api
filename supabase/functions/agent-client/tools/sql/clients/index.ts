import {
  assertPublicHost,
  assertPublicUrl,
} from "../../../../_shared/net_guard.ts";
import type { SQLToolConfig } from "../config.ts";
import type { BaseClient } from "./base.ts";
import { LibSQLClient } from "./libsql.ts";
import { MySQLClient } from "./mysql.ts";
import { PostgresClient } from "./postgres.ts";

export type { BaseClient };

// Factory function to create the appropriate client
export async function createDBClient(
  config: SQLToolConfig,
): Promise<BaseClient> {
  // F08: the destination is an admin's string; it must be a public host.
  if (config.driver === "libsql") {
    await assertPublicUrl(config.url, {
      protocols: ["libsql:", "https:", "http:", "wss:", "ws:"],
    });
  } else {
    await assertPublicHost(config.host);
  }

  switch (config.driver) {
    case "postgres":
      return new PostgresClient(config);
    case "mysql":
      return new MySQLClient(config);
    case "libsql":
      return new LibSQLClient(config);
    default:
      // @ts-ignore type never
      throw new Error(`Unsupported SQL driver: ${config.driver}`);
  }
}
