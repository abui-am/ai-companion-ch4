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
| `true` | Every turn's transcript and audio is saved |
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
  "endedAt": "2026-07-07T09:03:12Z"
}
```

| Field | Type | Notes |
|-------|------|-------|
| `id` | string | The voice session's UUID |
| `startedAt` | string (ISO 8601 UTC) | Set on first saved turn |
| `endedAt` | string (ISO 8601 UTC) \| null | Set on disconnect; `null` while the session is still live |

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

---

## Endpoints

### List sessions

```
GET /api/v1/conversations?from=<ISO8601>&to=<ISO8601>&limit=<n>
```

All query parameters are optional. `from`/`to` filter on `startedAt`; `limit` defaults to `50`.

**Response `200`:**

```json
{ "sessions": [ { "id": "...", "startedAt": "...", "endedAt": null } ] }
```

### Get one session

```
GET /api/v1/conversations/{id}
```

**Response `200`:** single Session object. **Response `404`:** session not found.

### List messages in a session

```
GET /api/v1/conversations/{id}/messages?limit=<n>&offset=<n>
```

Ordered oldest-first. `limit` defaults to `100`, `offset` defaults to `0`. **Response `404`** if `{id}` doesn't exist.

**Response `200`:**

```json
{ "messages": [ { "id": "cmsg_abc123", "role": "user", "content": "Hello there", "audioUrl": "...", "createdAt": "..." } ] }
```

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

export type ConversationSessionsResponse = { sessions: ConversationSession[] };
export type ConversationMessagesResponse = { messages: ConversationMessage[] };
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

---

## Errors

| Status | When |
|--------|------|
| `401` | Missing or invalid `Authorization` header |
| `404` | Session, message, or audio not found |
| `503` | Postgres unavailable (`GET /health` also fails) |

---

## Local setup

1. Start Postgres: `cd CompanionServer && docker-compose up -d`
2. Copy `.env.example` → `.env` and set `DEVICE_TOKEN`
3. Set `privacy.personalizationData` to `true` via [CONFIG_API.md](CONFIG_API.md) (it defaults to `true`)
4. Start server: `swift run CompanionServer`
5. Complete a voice session — its transcript and audio are saved automatically on each turn

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
- [STABLE_V1.md](STABLE_V1.md) — WebSocket voice protocol that produces the transcripts and audio saved here
