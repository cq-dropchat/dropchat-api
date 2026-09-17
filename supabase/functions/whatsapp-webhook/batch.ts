import type { SupabaseClient } from "@supabase/supabase-js";
import type {
  ContactAddressInsert,
  Database,
  MessageInsert,
  WebhookError,
} from "../_shared/supabase.ts";

/** What one webhook payload writes, collected before persisting. */
export type Batch = {
  messages: MessageInsert[];
  statuses: MessageInsert[];
  contacts_addresses: ContactAddressInsert[];
  // Coexistence edit/revoke events modify existing rows by their ORIGINAL id,
  // so they are applied as UPDATEs after the upserts rather than batched.
  // organization_id travels with each one: external ids are unique per
  // tenant (F03), so the update must name the tenant too.
  edits: {
    organization_id: string;
    original_message_id: string;
    text: string;
    timestamp: string;
  }[];
  revokes: {
    organization_id: string;
    original_message_id: string;
    timestamp: string;
  }[];
};

export function newBatch(): Batch {
  return {
    messages: [],
    statuses: [],
    contacts_addresses: [],
    edits: [],
    revokes: [],
  };
}

/** One change of one account, while it is being collected. */
export type AccountChange = {
  client: SupabaseClient<Database>;
  field: string;
  organization_id: string;
  organization_address: string;
  batch: Batch;
  /** `errors`-type messages, summarized per code after the change. */
  errors: Omit<WebhookError, "href">[];
};
