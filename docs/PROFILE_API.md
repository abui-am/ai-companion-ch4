# Profile API — Frontend Integration

REST endpoints for the single user's profile: their **name**, their **role/job**, and how much **focus time** they've logged **today**. Backs the Home page's "Who am I working with today?" card and "Today's summary → focus time," which are currently stored on-device only and need to persist server-side and sync across sessions.

There is exactly **one** profile per device (this is a single-user companion, same model as [MEMORY_API.md](MEMORY_API.md) and [TASK_API.md](TASK_API.md)) — so there is no user ID in any path; the bearer token identifies the device/user.

**Base URL:** `http://localhost:8080` (CompanionServer default)

**Auth:** Same bearer token as everything else (`DEVICE_TOKEN` in `.env`).

```
Authorization: Bearer <DEVICE_TOKEN>
```

---

## Profile object

```json
{
  "name": "yuyun",
  "role": "student",
  "focusSecondsToday": 2760,
  "date": "2026-07-08",
  "updatedAt": "2026-07-08T09:46:12Z"
}
```

| Field | Type | Notes |
|-------|------|-------|
| `name` | string \| null | Display name. `null`/`""` means "not set yet" — the UI shows a placeholder. Max 100 chars. |
| `role` | string \| null | The user's role/job, free text (e.g. "student", "remote worker", "founder"). `null`/`""` means not set. Max 100 chars. |
| `focusSecondsToday` | integer | Total focus time accumulated **today**, in **seconds**. Resets to `0` at local midnight (see [Daily reset](#daily-reset)). Never negative. |
| `date` | string (`YYYY-MM-DD`, server-local) | The day `focusSecondsToday` is counting for. Lets the client detect a day rollover. |
| `updatedAt` | string (ISO 8601 UTC) | Last time any field changed. |

> **Why seconds, not minutes?** The app tracks focus sessions to the second (a session can end at, say, 46 seconds) and only rounds to minutes/hours for display. Storing seconds keeps totals exact; the client does its own `h/m` formatting.

---

## Endpoints

### 1. Get the profile

```
GET /api/v1/profile
```

Returns the profile. If none exists yet, the server returns a default empty one (`name`/`role` null, `focusSecondsToday` 0) rather than `404`, so the UI can render its placeholders on first launch.

**Response `200`:**

```json
{
  "name": "yuyun",
  "role": "student",
  "focusSecondsToday": 2760,
  "date": "2026-07-08",
  "updatedAt": "2026-07-08T09:46:12Z"
}
```

**Example:**

```bash
curl -s \
  -H "Authorization: Bearer $DEVICE_TOKEN" \
  "http://localhost:8080/api/v1/profile"
```

---

### 2. Update name and/or role

```
PATCH /api/v1/profile
Content-Type: application/json
```

Partial update. Send only the fields you want to change; omitted fields are left untouched. This is the endpoint behind the pencil ✎ "Save" button on the Home card.

**Request body** (both fields optional):

```json
{
  "name": "yuyun",
  "role": "student"
}
```

| Field | Type | Notes |
|-------|------|-------|
| `name` | string | Optional. Send `""` to clear it back to "not set". Trimmed of surrounding whitespace. Max 100 chars. |
| `role` | string | Optional. Same rules as `name`. |

- Sending `{}` is a valid no-op and returns the current profile.
- `focusSecondsToday` and `date` are **not** writable here — use the focus endpoint below.

**Response `200`:** the full updated profile object (same shape as `GET`).

**Example:**

```bash
curl -s -X PATCH \
  -H "Authorization: Bearer $DEVICE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"yuyun","role":"student"}' \
  "http://localhost:8080/api/v1/profile"
```

---

### 3. Add focus time for today

```
POST /api/v1/profile/focus
Content-Type: application/json
```

**Additive.** Call this once when a focus session ends, with the number of seconds that session lasted. The server adds it to today's running total and returns the new total. (The app accumulates focus the same way — each finished session's seconds are added to the day's tally.)

**Request body:**

```json
{
  "seconds": 2760
}
```

| Field | Type | Notes |
|-------|------|-------|
| `seconds` | integer | Required. Seconds to **add** to today's total. Must be `>= 0`. Reject negatives with `400`. |

**Response `200`:** the full profile with the updated `focusSecondsToday`.

```json
{
  "name": "yuyun",
  "role": "student",
  "focusSecondsToday": 5520,
  "date": "2026-07-08",
  "updatedAt": "2026-07-08T10:32:41Z"
}
```

**Example:**

```bash
# a 46-minute session just ended (46 * 60 = 2760)
curl -s -X POST \
  -H "Authorization: Bearer $DEVICE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"seconds":2760}' \
  "http://localhost:8080/api/v1/profile/focus"
```

> **Note on retries / double-counting.** Because this endpoint *adds*, a retried request would double-count. Keep the client responsible for only calling it once per completed session.

---

## Daily reset

`focusSecondsToday` counts a single calendar day in the **server's local timezone** (`TimeZone.current` on the machine running CompanionServer).

- On any `GET`/`PATCH`/`POST` where the server's current local date is later than the stored `date`, the server first resets `focusSecondsToday` to `0` and sets `date` to today — *then* applies the request.
- So a `POST /focus` that's the first call of a new day starts the total fresh; the client never has to send a "reset" call.
- The client also gets `date` back on every response, so if the app has been open across midnight it can notice the rollover and refresh.

---

## Summary of endpoints

| Method | Path | Purpose | Body |
|--------|------|---------|------|
| `GET` | `/api/v1/profile` | Read name, role, today's focus | — |
| `PATCH` | `/api/v1/profile` | Update name and/or role | `{ name?, role? }` |
| `POST` | `/api/v1/profile/focus` | Add seconds to today's focus | `{ seconds }` |

---

## Frontend examples

### TypeScript types

```typescript
export type Profile = {
  name: string | null;
  role: string | null;
  focusSecondsToday: number;
  date: string;        // "YYYY-MM-DD", server-local
  updatedAt: string;   // ISO 8601 UTC
};

export type ProfileUpdate = {
  name?: string;
  role?: string;
};

export type FocusAdd = {
  seconds: number;
};
```

### Fetch, update, and log focus

```typescript
const token = process.env.DEVICE_TOKEN!;
const baseURL = "http://localhost:8080";
const auth = { Authorization: `Bearer ${token}` };

export async function getProfile(): Promise<Profile> {
  const res = await fetch(`${baseURL}/api/v1/profile`, { headers: auth });
  if (!res.ok) throw new Error(`profile fetch failed: ${res.status}`);
  return res.json();
}

export async function updateProfile(patch: ProfileUpdate): Promise<Profile> {
  const res = await fetch(`${baseURL}/api/v1/profile`, {
    method: "PATCH",
    headers: { ...auth, "Content-Type": "application/json" },
    body: JSON.stringify(patch),
  });
  if (!res.ok) throw new Error(`profile update failed: ${res.status}`);
  return res.json();
}

export async function addFocus(seconds: number): Promise<Profile> {
  const res = await fetch(`${baseURL}/api/v1/profile/focus`, {
    method: "POST",
    headers: { ...auth, "Content-Type": "application/json" },
    body: JSON.stringify({ seconds }),
  });
  if (!res.ok) throw new Error(`focus add failed: ${res.status}`);
  return res.json();
}
```

### Format focus time for display

```typescript
export function formatFocusTime(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}
```

### Swift (URLSession)

```swift
struct Profile: Decodable {
    let name: String?
    let role: String?
    let focusSecondsToday: Int
    let date: String
    let updatedAt: Date
}

func fetchProfile(token: String) async throws -> Profile {
    var request = URLRequest(url: URL(string: "http://localhost:8080/api/v1/profile")!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw URLError(.badServerResponse)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Profile.self, from: data)
}

func addFocus(seconds: Int, token: String) async throws -> Profile {
    var request = URLRequest(url: URL(string: "http://localhost:8080/api/v1/profile/focus")!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(["seconds": seconds])

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw URLError(.badServerResponse)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Profile.self, from: data)
}
```

---

## Today's Summary (Home page)

The Home "Today's Summary" card shows three numbers. **Two of them come from existing APIs; focus time comes from this Profile API.**

| Row | Value shown | Source |
|-----|-------------|--------|
| Upcoming events | count of today's events that haven't started yet, plus "in _Xh Ym_" until the next one | [Calendar API](CALENDAR_API.md) `GET /api/v1/calendar/events` |
| Tiny quest(s) | count of today's events flagged **important** (`isImportant == true`) | Calendar API (same call) |
| Focus time | today's focus total, shown as `Xh Ym` | Profile API `focusSecondsToday` (above) |

> ⚠️ **"Tiny quests" = important calendar events, not tasks.** In the current app this row counts today's `isImportant` events, *not* items from the [Task API](TASK_API.md). If you actually want it to mean "open tasks due today," source it from `GET /api/v1/tasks` (filter `dueAt` on today and `completed != true`) and rename the field below to match — decide this before wiring it.

**Recommended approach:** compute on the client. Home already fetches calendar events and the profile, so it can do the filtering and counting itself. No extra backend endpoint is required.

---

## Errors

| Status | When |
|--------|------|
| `400` | Malformed JSON, `name`/`role` over 100 chars, or `seconds` missing/negative/not an integer |
| `401` | Missing or invalid `Authorization` header |
| `503` | Datastore unavailable (`GET /health` also fails) |

Error body shape matches the other APIs:

```json
{ "error": { "message": "seconds must be a non-negative integer" } }
```

---

## Local setup

1. Start Postgres: `cd CompanionServer && docker-compose up -d`
2. Copy `.env.example` → `.env` and set `DEVICE_TOKEN`
3. Start server: `swift run CompanionServer`
4. A default profile row is created on first boot (`name`/`role` null, `focusSecondsToday` 0)

### Running API tests

```bash
cd CompanionServer
swift test --filter ProfileAPITests
```

Tests use `DATABASE_URL` (default `postgres://postgres:postgres@localhost:5432/companion`) and skip automatically if Postgres is unavailable.

---

## Related docs

- [MEMORY_API.md](MEMORY_API.md) — long-term memory list/delete (same auth, same server)
- [TASK_API.md](TASK_API.md) — task REST endpoints
- [CALENDAR_API.md](CALENDAR_API.md) — calendar REST endpoints
- [CONFIG_API.md](CONFIG_API.md) — `privacy.personalizationData` toggle
- [../CompanionServer/.env.example](../CompanionServer/.env.example) — `DEVICE_TOKEN`, `DATABASE_URL`
