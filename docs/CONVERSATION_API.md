# Conversation History API — Frontend Integration

Read-only REST API for browsing past voice conversations. `VoiceSession` persists transcripts and WAV audio to Postgres and the filesystem after each turn — this API only reads that data back; there is no write endpoint.

**Base URL:** `http://localhost:8080` (CompanionServer default)

**Auth:** Same bearer token as WebSocket, Calendar, Config, and Task APIs (`DEVICE_TOKEN` in `.env`).

```
Authorization: Bearer <DEVICE_TOKEN>
```

---

## Privacy — read this first

Persistence is gated by `privacy.personalizationData` (see [CONFIG_API.md](CONFIG_API.md)):

| `personalizationData` | Behavior |
|------------------------|----------|
| `true` | Every turn's transcript, audio, and tool calls are saved |
| `false` | Nothing is saved — no DB rows, no WAV files |

The flag is read once per session at `session.start` and cached for that session's duration, matching how `personality` and `language` are applied. Toggling it in Settings takes effect on the **next** voice session, not mid-call.

Saving costs **zero additional OpenAI tokens** — the transcript and PCM audio are already produced by the voice pipeline for every turn; persistence is a local filesystem + Postgres write after the turn completes, not a new model request.

---

## Session and message objects

A **session** covers one WebSocket connection (from `session.start` to disconnect). Each **message** is one side of a turn — a session with two turns has up to four messages (`user`, `assistant`, `user`, `assistant`).

```json
{
  "id": "3F2A1B4C-...",
  "startedAt": "2026-07-07T09:00:00Z",
  "endedAt": "2026-07-07T09:03:12Z",
  "voiceCount": 3
}
```

| Field | Type | Notes |
|-------|------|-------|
| `id` | string | The voice session's UUID |
| `startedAt` | string (ISO 8601 UTC) | Set on first saved turn |
| `endedAt` | string (ISO 8601 UTC) \| null | Set on disconnect; `null` while the session is still live |
| `voiceCount` | integer | Number of distinct voice turns in this session (`turn-1`, `turn-2`, …); `0` when no messages have been saved yet |

```json
{
  "id": "cmsg_abc123",
  "sessionId": "3F2A1B4C-...",
  "turnId": "turn-1",
  "role": "user",
  "content": "Hello there",
  "audioUrl": "/api/v1/conversations/3F2A1B4C-.../messages/cmsg_abc123/audio",
  "createdAt": "2026-07-07T09:00:05Z"
}
```

| Field | Type | Notes |
|-------|------|-------|
| `id` | string | Stable ID, prefix `cmsg_` |
| `sessionId` | string | Parent session |
| `turnId` | string | `turn-1`, `turn-2`, ... — pairs the user/assistant side of one turn |
| `role` | enum | `user` \| `assistant` |
| `content` | string | Transcript text; empty string if transcription failed but audio was still saved |
| `audioUrl` | string \| null | Present only when audio was captured for this message — see [Audio](#audio) |
| `createdAt` | string (ISO 8601 UTC) | |

A **tool call** records one sub-agent lookup (`tasks`, `calendar`, `web_search`, `memory`) the model made while forming its reply to a turn:

```json
{
  "id": "ctool_a1b2c3d4e5f6",
  "tool": "calendar",
  "action": "list",
  "label": "list",
  "status": "success",
  "input": { "action": "list" },
  "output": { "summary": "Found 2 event(s).", "events": [] },
  "summary": "Found 2 event(s).",
  "createdAt": "2026-07-07T09:00:03Z"
}
```

| Field | Type | Notes |
|-------|------|-------|
| `id` | string | Stable ID, prefix `ctool_` |
| `tool` | enum | `tasks` \| `calendar` \| `web_search` \| `memory` |
| `action` | string \| null | From `input.action` (`tasks`/`calendar`/`memory`); `null` for `web_search` |
| `label` | string | Short UI text, e.g. `"list"`, `"create: Buy milk"`, `"remember: User's dog is named Max"`, or the search query |
| `status` | enum | `success` \| `error` \| `duplicate` — see below |
| `input` | object | Parsed arguments the model sent the tool |
| `output` | object | Parsed result the tool returned |
| `summary` | string \| null | Convenience copy of `output.summary`, for a collapsed row |
| `createdAt` | string (ISO 8601 UTC) | |

`status` is derived once, server-side, so every client agrees:

| Condition | `status` |
|-----------|----------|
| `output.error` is present | `error` |
| `output.summary` is `"Already looked that up this turn."` | `duplicate` — the model asked for the same thing twice in one turn |
| otherwise | `success` |

---

## Endpoints

### List sessions

```
GET /api/v1/conversations?from=<ISO8601>&to=<ISO8601>&limit=<n>
```

All query parameters are optional. `from`/`to` filter on `startedAt`; `limit` defaults to `50`.

**Response `200`:**

```json
{ "sessions": [ { "id": "...", "startedAt": "...", "endedAt": null, "voiceCount": 3 } ] }
```

Each session object includes `voiceCount` so list UIs can show how many voice turns happened without fetching `/history`.

### Get one session

```
GET /api/v1/conversations/{id}
```

**Response `200`:** single Session object (includes `voiceCount`). **Response `404`:** session not found.

### List messages in a session

```
GET /api/v1/conversations/{id}/messages?limit=<n>&offset=<n>
```

Ordered oldest-first. `limit` defaults to `100`, `offset` defaults to `0`. **Response `404`** if `{id}` doesn't exist.

**Response `200`:**

```json
{ "messages": [ { "id": "cmsg_abc123", "role": "user", "content": "Hello there", "audioUrl": "...", "createdAt": "..." } ] }
```

### Get turn-grouped history (recommended for chat UIs)

```
GET /api/v1/conversations/{id}/history?limit=<n>&offset=<n>
```

The frontend-first alternative to `/messages`: groups each turn's user message, tool calls, and assistant reply into one object, so a client renders `turns.map(...)` with no merging or role-filtering of its own. `limit`/`offset` paginate on **turns**, not raw rows; `limit` defaults to `50`. **Response `404`** if `{id}` doesn't exist.

**Response `200`:**

```json
{
  "sessionId": "3F2A1B4C-...",
  "turns": [
    {
      "turnId": "turn-1",
      "user": {
        "id": "cmsg_abc123",
        "content": "What's on my calendar tomorrow?",
        "audioUrl": "/api/v1/conversations/3F2A1B4C-.../messages/cmsg_abc123/audio",
        "createdAt": "2026-07-07T09:00:02Z"
      },
      "toolCalls": [
        {
          "id": "ctool_a1b2c3d4e5f6",
          "tool": "calendar",
          "action": "list",
          "label": "list",
          "status": "success",
          "input": { "action": "list" },
          "output": { "summary": "Found 2 event(s).", "events": [] },
          "summary": "Found 2 event(s).",
          "createdAt": "2026-07-07T09:00:03Z"
        }
      ],
      "assistant": {
        "id": "cmsg_def456",
        "content": "You have two things tomorrow — team standup at 9 and lunch with Alex at noon.",
        "audioUrl": "/api/v1/conversations/3F2A1B4C-.../messages/cmsg_def456/audio",
        "createdAt": "2026-07-07T09:00:08Z"
      }
    }
  ]
}
```

A turn with no tool calls returns `"toolCalls": []`; a turn missing one side (e.g. transcription failed) returns `null` for `user` or `assistant`.

A turn where the model saved a memory looks the same, with `tool: "memory"`:

```json
{
  "id": "ctool_g7h8i9j0k1l2",
  "tool": "memory",
  "action": "remember",
  "label": "remember: User's dog is named Max",
  "status": "success",
  "input": { "action": "remember", "content": "User's dog is named Max" },
  "output": { "summary": "Saved memory.", "id": "mem_a1b2c3d4e5f6", "content": "User's dog is named Max", "updated": false },
  "summary": "Saved memory.",
  "createdAt": "2026-07-08T09:00:03Z"
}
```

Tool call history is a read-only record for UI replay — it is not itself a memory source. Durable facts recalled by the voice companion live only in the `memories` table; see [MEMORY_API.md](MEMORY_API.md).

### Download message audio

```
GET /api/v1/conversations/{id}/messages/{messageId}/audio
```

Streams the raw WAV file for one message. **Response `404`** if the message doesn't exist, doesn't belong to `{id}`, or has no audio (`audioUrl` was `null`).

**Response `200`:**

| Header | Value |
|--------|-------|
| `Content-Type` | `audio/wav` |
| `Content-Length` | file size in bytes |

**curl test:**

```bash
curl -H "Authorization: Bearer $DEVICE_TOKEN" \
  "http://localhost:8080/api/v1/conversations/3F2A1B4C-.../messages/cmsg_abc123/audio" \
  --output turn-1-user.wav
```

---

## Audio

Each turn can produce up to two WAV files:

| Message role | Source | Sample rate | Filename on disk |
|---------------|--------|-------------|-------------------|
| `user` | uplink mic capture | 16 kHz PCM16 mono | `{turnId}-uplink.wav` |
| `assistant` | downlink TTS reply | 24 kHz PCM16 mono | `{turnId}-downlink.wav` |

Files live under `CompanionServer/conversation-audio/{sessionId}/` — separate from the always-on `debug-audio/` dumps used for development. This directory is gitignored and never committed.

Audio is **not** served as a static file URL. Clients only reach it through the authenticated `.../audio` endpoint above, so `DEVICE_TOKEN` gates both metadata and playback. Rough disk usage: ~32 KB/second of uplink speech and ~48 KB/second of downlink speech (16-bit PCM, mono).

### Web playback (fetch-then-blob)

Browsers can't send an `Authorization` header on a raw `<audio src="...">`, so fetch the bytes first and hand the browser a blob URL:

```typescript
async function loadTurnAudio(baseUrl: string, token: string, audioUrl: string): Promise<string> {
  const res = await fetch(`${baseUrl}${audioUrl}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!res.ok) {
    throw new Error(`audio fetch failed: ${res.status}`);
  }
  const blob = await res.blob();
  return URL.createObjectURL(blob);
}

// <audio src={await loadTurnAudio(baseUrl, token, message.audioUrl)} controls />
```

### iOS / native

Same URL and bearer header on `URLSession`; write the response to a temp file or feed it directly into `AVAudioPlayer`.

---

## Frontend examples

### TypeScript types

```typescript
export type ConversationSession = {
  id: string;
  startedAt: string;
  endedAt: string | null;
  voiceCount: number;
};

export type ConversationMessage = {
  id: string;
  sessionId: string;
  turnId: string;
  role: "user" | "assistant";
  content: string;
  audioUrl: string | null;
  createdAt: string;
};

export type ToolName = "tasks" | "calendar" | "web_search" | "memory";
export type ToolCallStatus = "success" | "error" | "duplicate";

export type ConversationToolCall = {
  id: string;
  tool: ToolName;
  action: string | null;
  label: string;
  status: ToolCallStatus;
  input: Record<string, unknown>;
  output: Record<string, unknown>;
  summary: string | null;
  createdAt: string;
};

export type ConversationTurnMessage = {
  id: string;
  content: string;
  audioUrl: string | null;
  createdAt: string;
};

export type ConversationTurn = {
  turnId: string;
  user: ConversationTurnMessage | null;
  toolCalls: ConversationToolCall[];
  assistant: ConversationTurnMessage | null;
};

export type ConversationSessionsResponse = { sessions: ConversationSession[] };
export type ConversationMessagesResponse = { messages: ConversationMessage[] };
export type ConversationHistoryResponse = { sessionId: string; turns: ConversationTurn[] };
```

### Fetch a session's transcript

```typescript
const token = process.env.DEVICE_TOKEN!;
const baseURL = "http://localhost:8080";

export async function fetchMessages(sessionId: string): Promise<ConversationMessage[]> {
  const res = await fetch(`${baseURL}/api/v1/conversations/${sessionId}/messages`, {
    headers: { Authorization: `Bearer ${token}` },
  });

  if (!res.ok) {
    throw new Error(`messages fetch failed: ${res.status}`);
  }

  const data: ConversationMessagesResponse = await res.json();
  return data.messages;
}
```

### Fetch and render turn-grouped history

```typescript
export async function fetchHistory(sessionId: string): Promise<ConversationTurn[]> {
  const res = await fetch(`${baseURL}/api/v1/conversations/${sessionId}/history`, {
    headers: { Authorization: `Bearer ${token}` },
  });

  if (!res.ok) {
    throw new Error(`history fetch failed: ${res.status}`);
  }

  const data: ConversationHistoryResponse = await res.json();
  return data.turns;
}

// Rendering needs no merging of separate lists — just walk each turn in order.
for (const turn of await fetchHistory(sessionId)) {
  renderUserBubble(turn.user);
  for (const call of turn.toolCalls) {
    renderToolChip(call.label, call.status, call.summary ?? call.output.error);
  }
  renderAssistantBubble(turn.assistant);
}
```

---

## Live tool-call events (WebSocket)

During an active voice session, the server also emits `tool.start` and `tool.done` over the same `/ws` connection used for audio — see [STABLE_V1.md](STABLE_V1.md#tool-call-events). `tool.done`'s `call` field is the exact same `ConversationToolCall` shape shown above, so a companion app can share one rendering path between the live call and the persisted history it fetches afterward.

```json
{ "type": "tool.done", "session_id": "3F2A1B4C-...", "turn_id": "turn-1", "call": { "id": "ctool_...", "tool": "calendar", "status": "success", "...": "..." } }
```

---

## Errors

| Status | When |
|--------|------|
| `401` | Missing or invalid `Authorization` header |
| `404` | Session, message, tool call, or audio not found |
| `503` | Postgres unavailable (`GET /health` also fails) |

---

## Local setup

1. Start Postgres: `cd CompanionServer && docker-compose up -d`
2. Copy `.env.example` → `.env` and set `DEVICE_TOKEN`
3. Set `privacy.personalizationData` to `true` via [CONFIG_API.md](CONFIG_API.md) (it defaults to `true`)
4. Start server: `swift run CompanionServer`
5. Complete a voice session — its transcript, audio, and any tool calls are saved automatically on each turn

### Running API tests

```bash
cd CompanionServer
swift test --filter ConversationAPITests
```

Tests use `DATABASE_URL` (default `postgres://postgres:postgres@localhost:5432/companion`) and skip automatically if Postgres is unavailable.

---

## Related docs

- [CONFIG_API.md](CONFIG_API.md) — `privacy.personalizationData` toggle that gates this API's data
- [CALENDAR_API.md](CALENDAR_API.md) — Calendar REST API (same auth, same server)
- [MEMORY_API.md](MEMORY_API.md) — AI long-term memory; `memory` tool calls shown here are recorded there too
- [STABLE_V1.md](STABLE_V1.md) — WebSocket voice protocol that produces the transcripts and audio saved here
