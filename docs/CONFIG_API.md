# Config API — Frontend Integration

REST endpoint for the Settings page. Preferences are stored in Postgres as a single row and returned as JSON matching the view model.

**Base URL:** `http://localhost:8080` (CompanionServer default)

**Auth:** Same bearer token as WebSocket and the Calendar API (`DEVICE_TOKEN` in `.env`).

```
Authorization: Bearer <DEVICE_TOKEN>
```

---

## Mock connection — read this first

Device pairing is **not implemented**. The `connection` field is always a hardcoded value:

```json
{ "deviceName": "Bocil-Desk-01", "status": "paired" }
```

- `GET /api/v1/config` always returns this value.
- `PATCH /api/v1/config` **silently ignores** a `connection` key if you send one — it never errors, it just has no effect.
- There is no endpoint to unpair or rename a device. If your Settings UI has a "Forget this device" button, disable it or show a "Coming soon" state — wiring it up is a separate, not-yet-planned feature.

Everything else in the response (`personality`, `appearance`, `notifications`, `privacy`, `language`) is real, persisted, and editable.

---

## Config object

Mirrors what the Settings screen renders:

```json
{
  "personality": "calm",
  "connection": {
    "deviceName": "Bocil-Desk-01",
    "status": "paired"
  },
  "appearance": "light",
  "notifications": {
    "taskReminders": true,
    "calendarAlerts": true,
    "remindBeforeMinutes": 10
  },
  "privacy": {
    "cameraAccess": true,
    "personalizationData": true
  },
  "language": "english"
}
```

| Field | Type | Notes |
|-------|------|-------|
| `personality` | enum | `calm` \| `energetic` \| `professional` — also changes the voice companion's tone on its next session |
| `connection.deviceName` | string | Mock — see above |
| `connection.status` | string | Mock — always `paired` |
| `appearance` | enum | `system` \| `light` \| `dark` |
| `notifications.taskReminders` | boolean | |
| `notifications.calendarAlerts` | boolean | |
| `notifications.remindBeforeMinutes` | number | One of `5`, `10`, `15`, `30` |
| `privacy.cameraAccess` | boolean | |
| `privacy.personalizationData` | boolean | |
| `language` | enum | `english` \| `spanish` \| `french` — also changes the voice companion's reply language on its next session |

### UI label mapping

For radio-button style sections (personality, appearance, language), map enum values to the labels shown in the mockup:

| Field | Value | Label | Subtitle |
|-------|-------|-------|----------|
| `personality` | `calm` | Calm | Gentle, thoughtful nudges |
| `personality` | `energetic` | Energetic | Uplifting, motivational |
| `personality` | `professional` | Professional | Direct, efficient |
| `appearance` | `system` | System | Follow your system settings |
| `appearance` | `light` | Light | Always light mode |
| `appearance` | `dark` | Dark | Always dark mode |
| `language` | `english` | English | English (US) |
| `language` | `spanish` | Spanish | Español |
| `language` | `french` | French | Français |

---

## Endpoints

### Get config

```
GET /api/v1/config
```

**Response `200`:** the Config object shown above.

### Update config

```
PATCH /api/v1/config
Content-Type: application/json
```

Send only the fields you want to change — this is a partial update, not a full replace. Omitted fields keep their current value.

**Example — change personality only:**

```json
{ "personality": "energetic" }
```

**Example — change a subset of notification settings:**

```json
{
  "notifications": {
    "remindBeforeMinutes": 30,
    "taskReminders": false
  }
}
```

`notifications.calendarAlerts` is untouched by this request and keeps its previous value.

**Response `200`:** the full, updated Config object (same shape as `GET`).

**Response `400`:** invalid enum value (e.g. `"personality": "grumpy"`) or `remindBeforeMinutes` outside `{5, 10, 15, 30}`.

---

## Frontend examples

### TypeScript types

```typescript
export type Personality = "calm" | "energetic" | "professional";
export type Appearance = "system" | "light" | "dark";
export type Language = "english" | "spanish" | "french";

export type Connection = {
  deviceName: string;
  status: string;
};

export type Notifications = {
  taskReminders: boolean;
  calendarAlerts: boolean;
  remindBeforeMinutes: 5 | 10 | 15 | 30;
};

export type Privacy = {
  cameraAccess: boolean;
  personalizationData: boolean;
};

export type Config = {
  personality: Personality;
  connection: Connection;
  appearance: Appearance;
  notifications: Notifications;
  privacy: Privacy;
  language: Language;
};

/// Partial update body — every field optional, nested objects also partial.
export type ConfigPatch = Partial<{
  personality: Personality;
  appearance: Appearance;
  notifications: Partial<Notifications>;
  privacy: Partial<Privacy>;
  language: Language;
}>;
```

### Fetch and update config

```typescript
const token = process.env.DEVICE_TOKEN!;
const baseURL = "http://localhost:8080";

export async function fetchConfig(): Promise<Config> {
  const res = await fetch(`${baseURL}/api/v1/config`, {
    headers: { Authorization: `Bearer ${token}` },
  });

  if (!res.ok) {
    throw new Error(`config fetch failed: ${res.status}`);
  }

  return res.json();
}

export async function patchConfig(patch: ConfigPatch): Promise<Config> {
  const res = await fetch(`${baseURL}/api/v1/config`, {
    method: "PATCH",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(patch),
  });

  if (!res.ok) {
    throw new Error(`config update failed: ${res.status}`);
  }

  return res.json();
}
```

Do not send a `connection` key in `patch` — it is not part of `ConfigPatch` and would be dropped by the server anyway.

### Swift (URLSession)

```swift
struct Config: Decodable {
    let personality: String
    let appearance: String
    let language: String
}

func fetchConfig(token: String) async throws -> Config {
    var request = URLRequest(url: URL(string: "http://localhost:8080/api/v1/config")!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw URLError(.badServerResponse)
    }
    return try JSONDecoder().decode(Config.self, from: data)
}
```

---

## Errors

| Status | When |
|--------|------|
| `401` | Missing or invalid `Authorization` header |
| `400` | Invalid enum value or `remindBeforeMinutes` outside `{5, 10, 15, 30}` |
| `503` | Postgres unavailable (`GET /health` also fails) |

---

## Local setup

1. Start Postgres: `cd CompanionServer && docker-compose up -d`
2. Copy `.env.example` → `.env` and set `DEVICE_TOKEN`
3. Start server: `swift run CompanionServer`
4. A default config row is seeded on first boot (matches the values in the Config object example above)

### Running API tests

```bash
cd CompanionServer
swift test --filter ConfigAPITests
```

Tests use `DATABASE_URL` (default `postgres://postgres:postgres@localhost:5432/companion`) and skip automatically if Postgres is unavailable.

---

## Related docs

- [CALENDAR_API.md](CALENDAR_API.md) — Calendar REST API (same auth, same server)
- [STABLE_V1.md](STABLE_V1.md) — WebSocket voice protocol; `personality` and `language` from this API are applied to the voice pipeline at the start of each session
