# Memory API — Frontend Integration

REST endpoints for browsing and deleting the AI companion's long-term memory. Memories are durable facts about the user (name, preferences, relationships, routines) stored as OpenAI embeddings in Postgres (pgvector) and recalled by the voice companion across sessions.

**Writes are voice-only.** The `memory` tool (`remember`, `search`, `forget`, `list`) is called by the model during a voice session — there is no `POST` endpoint here. This API exists for debugging and a Settings-style "manage memories" list/delete UI.

**Base URL:** `http://localhost:8080` (CompanionServer default)

**Auth:** Same bearer token as WebSocket (`DEVICE_TOKEN` in `.env`).

```
Authorization: Bearer <DEVICE_TOKEN>
```

**Privacy:** Gated by `privacy.personalizationData` (see [CONFIG_API.md](CONFIG_API.md)) — the same flag that gates conversation history. When personalization is off:

- The voice `memory` tool returns a friendly error and makes no writes.
- Recent memories are not injected into the system prompt at session start.
- `GET /api/v1/memories` returns an empty list rather than erroring, so a Settings UI can render "no memories" instead of a broken state.

---

## Memory object

```json
{
  "id": "mem_a1b2c3d4e5f6",
  "content": "User's dog is named Max",
  "source": "tool",
  "createdAt": "2026-07-08T09:00:00Z"
}
```

| Field | Type | Notes |
|-------|------|-------|
| `id` | string | Stable ID, prefix `mem_` |
| `content` | string | The saved fact, one sentence, max 500 characters |
| `source` | string | Always `tool` in v1 — reserved for future non-tool write paths |
| `createdAt` | string (ISO 8601 UTC) | |

The stored embedding vector is never returned by this API.

---

## Endpoints

### List memories

```
GET /api/v1/memories?limit=<n>
```

`limit` is optional, defaults to `100`. Ordered newest first.

**Response `200`:**

```json
{
  "memories": [
    { "id": "mem_a1b2c3d4e5f6", "content": "User's dog is named Max", "source": "tool", "createdAt": "2026-07-08T09:00:00Z" }
  ]
}
```

Returns `{ "memories": [] }` when `privacy.personalizationData` is off.

**Example:**

```bash
curl -s \
  -H "Authorization: Bearer $DEVICE_TOKEN" \
  "http://localhost:8080/api/v1/memories"
```

### Delete a memory

```
DELETE /api/v1/memories/{id}
```

**Response `204`:** memory deleted.

**Response `404`:** memory ID not found.

**Example:**

```bash
curl -s -X DELETE \
  -H "Authorization: Bearer $DEVICE_TOKEN" \
  "http://localhost:8080/api/v1/memories/mem_a1b2c3d4e5f6"
```

---

## How memory works in voice sessions

- **Session start (free):** the 8 most recent memories are listed into the model's system prompt as "Known facts about this user" — no embedding call, so recall works on a brand-new connection without the user having to ask the AI to "check its memory."
- **On demand:** the model calls `memory.search` with a natural-language query when the user references something older or not in that list. Results below a similarity threshold are dropped, so unrelated memories are never surfaced.
- **Remember:** the model calls `memory.remember` when the user asks it to remember something, or a durable fact clearly comes up. A near-duplicate check updates the existing row instead of creating a new one.
- **Forget:** the model calls `memory.forget` with a natural-language `query` (not an ID — users say "forget my dog's name," not `mem_abc`). The closest matching memory above the same similarity threshold is deleted.

---

## Frontend examples

### TypeScript types

```typescript
export type Memory = {
  id: string;
  content: string;
  source: string;
  createdAt: string;
};

export type MemoriesResponse = {
  memories: Memory[];
};
```

### Fetch and delete memories

```typescript
const token = process.env.DEVICE_TOKEN!;
const baseURL = "http://localhost:8080";

export async function fetchMemories(): Promise<Memory[]> {
  const res = await fetch(`${baseURL}/api/v1/memories`, {
    headers: { Authorization: `Bearer ${token}` },
  });

  if (!res.ok) {
    throw new Error(`memories fetch failed: ${res.status}`);
  }

  const data: MemoriesResponse = await res.json();
  return data.memories;
}

export async function deleteMemory(id: string): Promise<void> {
  const res = await fetch(`${baseURL}/api/v1/memories/${id}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${token}` },
  });

  if (!res.ok) {
    throw new Error(`memory delete failed: ${res.status}`);
  }
}
```

---

## Errors

| Status | When |
|--------|------|
| `401` | Missing or invalid `Authorization` header |
| `404` | Memory ID not found (`DELETE` only) |
| `503` | Postgres unavailable (`GET /health` also fails) |

---

## Local setup

1. `docker-compose.yaml` now uses the `pgvector/pgvector:pg17` image (adds the `vector` extension). If you already have a Postgres volume from before this change, recreate it once: `cd CompanionServer && docker compose down -v && docker compose up -d`.
2. Copy `.env.example` → `.env` and set `DEVICE_TOKEN`, `OPENAI_API_KEY` (embeddings use the same key as the Realtime API).
3. Start server: `swift run CompanionServer` — this creates the `vector` extension and `memories` table on boot.
4. Set `privacy.personalizationData` to `true` via [CONFIG_API.md](CONFIG_API.md) (it defaults to `true`).
5. Start a voice session and say "remember my dog's name is Max" — confirm it later with `GET /api/v1/memories`.

### Running API tests

```bash
cd CompanionServer
swift test --filter MemoryAPITests
```

Repository tests use fixed, orthogonal test vectors rather than calling the live OpenAI Embeddings API. Tests use `DATABASE_URL` (default `postgres://postgres:postgres@localhost:5432/companion`) and skip automatically if Postgres is unavailable.

---

## Related docs

- [CONFIG_API.md](CONFIG_API.md) — `privacy.personalizationData` toggle that gates this API's data
- [CONVERSATION_API.md](CONVERSATION_API.md) — `memory` tool calls also appear in persisted conversation history
- [TASK_API.md](TASK_API.md) — Task REST endpoints (same auth, same server)
