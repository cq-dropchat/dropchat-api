// F08. Where an agent tool may connect.
//
// SQL, HTTP and MCP tools take their destination from agents.extra, which an
// organization's admin writes. Without a check, an admin points one at the
// platform's own network — the project database, Kong, the cloud metadata
// address — and the Edge Function connects from inside it. Every tool resolves
// its destination through here first:
//
//   - IP literals must be public (not loopback, private, link-local, CGNAT,
//     multicast, reserved, or IPv4-mapped versions of those);
//   - hostnames must not be internal names (single labels like `kong` or
//     `db`, `localhost`, `*.internal`, `*.local`), and EVERY address they
//     resolve to must be public — a public name pointing at 10.0.0.7 is the
//     same attack.
//
// The check runs once, before connecting; a DNS answer that changes between
// the check and the connection (rebinding) is not covered, which is the limit
// of doing this without a proxy.
//
// Local development needs the opposite (the repo's own MCP server lives at
// api.supabase.internal): AGENT_TOOL_ALLOWED_HOSTS is a comma-separated list
// of hostnames exempt from the check. Never set it in production.

export class DestinationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DestinationError";
  }
}

export type Resolver = (host: string) => Promise<string[]>;

export const denoResolver: Resolver = async (host) => {
  const lookups = await Promise.allSettled([
    Deno.resolveDns(host, "A"),
    Deno.resolveDns(host, "AAAA"),
  ]);
  return lookups.flatMap((r) => r.status === "fulfilled" ? r.value : []);
};

export type GuardOptions = {
  resolver?: Resolver;
  allowedHosts?: string[];
};

function envAllowedHosts(): string[] {
  try {
    return (Deno.env.get("AGENT_TOOL_ALLOWED_HOSTS") ?? "")
      .split(",")
      .map((h) => h.trim().toLowerCase())
      .filter(Boolean);
  } catch {
    return [];
  }
}

function parseIPv4(ip: string): number[] | null {
  const parts = ip.split(".");
  if (parts.length !== 4) return null;
  const octets = parts.map((p) => (/^\d{1,3}$/.test(p) ? Number(p) : NaN));
  return octets.every((o) => o >= 0 && o <= 255) ? octets : null;
}

function isPrivateIPv4([a, b]: number[]): boolean {
  return a === 0 || // "this" network
    a === 10 ||
    a === 127 ||
    (a === 100 && b >= 64 && b <= 127) || // CGNAT
    (a === 169 && b === 254) || // link-local, cloud metadata
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) ||
    (a === 192 && b === 0) || // IETF protocol assignments
    (a === 198 && (b === 18 || b === 19)) || // benchmarking
    a >= 224; // multicast, reserved, broadcast
}

/** True for any address a tool must not reach. Non-IPs return false. */
export function isPrivateAddress(ip: string): boolean {
  const host = ip.replace(/^\[|\]$/g, "").toLowerCase();

  const v4 = parseIPv4(host);
  if (v4) return isPrivateIPv4(v4);

  if (!host.includes(":")) return false;

  // IPv4-mapped / -compatible (::ffff:10.0.0.1)
  const mapped = host.match(/^::(?:ffff:)?(\d+\.\d+\.\d+\.\d+)$/);
  if (mapped) {
    const inner = parseIPv4(mapped[1]);
    return inner ? isPrivateIPv4(inner) : true;
  }

  if (host === "::" || host === "::1") return true;

  const first = parseInt(host.split(":")[0] || "0", 16);
  return (first & 0xfe00) === 0xfc00 || // fc00::/7 unique local
    (first & 0xffc0) === 0xfe80 || // fe80::/10 link-local
    (first & 0xff00) === 0xff00; // multicast
}

function isIPLiteral(host: string): boolean {
  const h = host.replace(/^\[|\]$/g, "");
  return parseIPv4(h) !== null || h.includes(":");
}

/** Names that only mean something inside a network. */
export function isBlockedHostname(host: string): boolean {
  const h = host.toLowerCase().replace(/\.$/, "");
  if (isIPLiteral(h)) return false;
  return !h.includes(".") || // kong, db, rest, storage …
    h === "localhost" ||
    h.endsWith(".localhost") ||
    h.endsWith(".internal") ||
    h.endsWith(".local") ||
    h.endsWith(".lan") ||
    h.endsWith(".home.arpa");
}

/** Throws DestinationError unless `host` is a public destination. */
export async function assertPublicHost(
  host: string,
  { resolver = denoResolver, allowedHosts = envAllowedHosts() }: GuardOptions =
    {},
): Promise<void> {
  const h = host.toLowerCase().replace(/^\[|\]$/g, "").replace(/\.$/, "");

  if (!h) throw new DestinationError("Destination host is empty");

  if (allowedHosts.includes(h)) return;

  if (isIPLiteral(h)) {
    if (isPrivateAddress(h)) {
      throw new DestinationError(`Destination ${h} is not a public address`);
    }
    return;
  }

  if (isBlockedHostname(h)) {
    throw new DestinationError(`Destination ${h} is an internal name`);
  }

  const addresses = await resolver(h);

  if (addresses.length === 0) {
    throw new DestinationError(`Destination ${h} does not resolve`);
  }

  const blocked = addresses.find(isPrivateAddress);
  if (blocked) {
    throw new DestinationError(
      `Destination ${h} resolves to a non-public address (${blocked})`,
    );
  }
}

/**
 * Parses `raw` and checks its scheme and host. Returns the URL so callers
 * connect to exactly what was checked.
 */
export async function assertPublicUrl(
  raw: string,
  {
    protocols = ["https:", "http:"],
    ...options
  }: GuardOptions & { protocols?: string[] } = {},
): Promise<URL> {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new DestinationError(`Destination ${raw} is not a valid URL`);
  }

  if (!protocols.includes(url.protocol)) {
    throw new DestinationError(
      `Destination scheme ${url.protocol} is not allowed`,
    );
  }

  await assertPublicHost(url.hostname, options);
  return url;
}
