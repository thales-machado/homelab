// Minimal sidecar behind the /api/homelab-containers endpoint of
// thalesmachado.net. Plain nginx cannot aggregate or reshape the JSON of two
// calls, so this is its own container instead of nginx logic.
//
// It queries the Komodo API directly (same network, komodo-core:9120 on
// zangetsu), one call per server, and sums both. ListDockerContainers needs
// params.server (the server NAME, not its id) and answers with an array of
// containers, so its length is the count.
//
// KOMODO_API_KEY/SECRET are the same pair Homepage already uses (env_file,
// never hardcoded, never in the website repo).

const KEY = Deno.env.get("KOMODO_API_KEY");
const SECRET = Deno.env.get("KOMODO_API_SECRET");
if (!KEY || !SECRET) {
  throw new Error("KOMODO_API_KEY/KOMODO_API_SECRET not set");
}

const KOMODO_URL = "http://komodo-core:9120/read";
const HOSTS = ["zangetsu", "urahara"];

async function countFor(server: string): Promise<number> {
  const res = await fetch(KOMODO_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Api-Key": KEY!,
      "X-Api-Secret": SECRET!,
    },
    body: JSON.stringify({ type: "ListDockerContainers", params: { server } }),
  });
  if (!res.ok) throw new Error(`komodo ${server}: HTTP ${res.status}`);
  const containers = await res.json();
  return Array.isArray(containers) ? containers.length : 0;
}

Deno.serve({ port: 3001 }, async () => {
  try {
    const counts = await Promise.all(HOSTS.map(countFor));
    const hosts = Object.fromEntries(HOSTS.map((h, i) => [h, counts[i]]));
    const total = counts.reduce((a, b) => a + b, 0);
    return Response.json({ total, hosts });
  } catch (e) {
    // 502 on purpose: the failure is upstream (Komodo), not in the sidecar
    return Response.json({ error: String(e) }, { status: 502 });
  }
});
