import type { SupabaseClient } from "@supabase/supabase-js";
import * as log from "../_shared/logger.ts";
import type { MessageInsert } from "../_shared/supabase.ts";
import {
  fetchMedia,
  MAX_STORAGE_UPLOAD_SIZE,
  uploadToStorage,
} from "../_shared/media.ts";

const API_VERSION = "v24.0";

/** The media id in a file message's uri → the file, in our storage. */
export async function downloadMediaItem({
  organization_id,
  access_token,
  message,
  client,
}: {
  organization_id: string;
  access_token: string;
  message: MessageInsert;
  client: SupabaseClient;
}): Promise<MessageInsert> {
  if (message.content.type !== "file") {
    return message;
  }

  const media_id = message.content.file.uri;
  const filename = message.content.file.name;

  // Fetch part 1: Get the download url using the media id
  const response = await fetch(
    `https://graph.facebook.com/${API_VERSION}/${media_id}`,
    {
      headers: { Authorization: `Bearer ${access_token}` },
    },
  );

  if (!response.ok) {
    throw Error("Could not download media item from WhatsApp servers", {
      cause: await response.json().catch(() => ({})),
    });
  }

  const mediaMetadata = (await response.json()) as {
    messaging_product: "whatsapp";
    url: string;
    mime_type: string;
    sha256: string;
    file_size: number;
    id: string;
  };

  log.info("Downloading media", {
    media_id,
    file_size: mediaMetadata.file_size,
    mime_type: mediaMetadata.mime_type,
  });

  message.content.file.size = mediaMetadata.file_size;

  // Check storage upload size limit before downloading
  if (mediaMetadata.file_size > MAX_STORAGE_UPLOAD_SIZE) {
    const sizeMB = (mediaMetadata.file_size / (1000 * 1000)).toFixed(1);
    const limitMB = (MAX_STORAGE_UPLOAD_SIZE / (1000 * 1000)).toFixed(0);

    log.warn("Media file exceeds storage upload limit", {
      media_id,
      file_size: mediaMetadata.file_size,
      limit: MAX_STORAGE_UPLOAD_SIZE,
    });

    // Preserve message with original WhatsApp media reference and error status
    message.status = {
      error: `File too large: ${sizeMB} MB (limit: ${limitMB} MB)`,
    };
    return message;
  }

  // Fetch part 2: Get the file using the download url
  const file = await fetchMedia(mediaMetadata.url, access_token);

  // Store the file
  const uri = await uploadToStorage(client, organization_id, file, filename);

  message.content.file.uri = uri; // Overwrite WA media id with the internal uri

  return message;
}
