# Calendar API — Frontend Integration

REST endpoints for `CalendarView`. Events are stored in Postgres and returned as JSON matching the view model.

**Base URL:** `http://localhost:8080` (CompanionServer default)

**Auth:** Same bearer token as WebSocket (`DEVICE_TOKEN` in `.env`).

```
Authorization: Bearer <DEVICE_TOKEN>
```

---

## Event object

Mirrors what `CalendarView` renders:

```json
{
  "id": "evt_abc123",
  "title": "Team Standup",
  "startsAt": "2026-07-07T09:00:00Z",
  "endsAt": "2026-07-07T09:30:00Z",
  "location": "Zoom",
  "isImportant": false,
  "notes": null
}
```

| Field | Type | Notes |
|-------|------|-------|
| `id` | string | Stable ID, prefix `evt_` |
| `title` | string | Event title |
| `startsAt` | string (ISO 8601 UTC) | Start time |
| `endsAt` | string (ISO 8601 UTC) | End time |
| `location` | string | Location label |
| `isImportant` | boolean | Highlight in UI |
| `notes` | string \| null | Optional notes |

---

## Endpoints

### List events

```
GET /api/v1/calendar/events?from=<ISO8601>&to=<ISO8601>
```

Query parameters are optional. When both are provided, returns events that **overlap** the range (`endsAt >= from` AND `startsAt <= to`).

**Response `200`:**

```json
{
  "events": [
    {
      "id": "evt_abc123",
      "title": "Team Standup",
      "startsAt": "2026-07-07T09:00:00Z",
      "endsAt": "2026-07-07T09:30:00Z",
      "location": "Zoom",
      "isImportant": false,
      "notes": null
    }
  ]
}
```

**Example — month view:**

```bash
curl -s \
  -H "Authorization: Bearer $DEVICE_TOKEN" \
  "http://localhost:8080/api/v1/calendar/events?from=2026-07-01T00:00:00Z&to=2026-07-31T23:59:59Z"
```

### Get one event

```
GET /api/v1/calendar/events/{id}
```

**Response `200`:** single Event object (same shape as list items).

**Response `404`:** event not found.

### Create event

```
POST /api/v1/calendar/events
Content-Type: application/json
```

**Request body:**

```json
{
  "title": "Dentist",
  "startsAt": "2026-07-08T14:00:00Z",
  "endsAt": "2026-07-08T15:00:00Z",
  "location": "Clinic",
  "isImportant": true,
  "notes": "Bring insurance card"
}
```

**Response `200`:** created Event object (server assigns `id`).

**Response `400`:** `endsAt` is not after `startsAt`.

---

## Frontend examples

### TypeScript types

```typescript
export type CalendarEvent = {
  id: string;
  title: string;
  startsAt: string;
  endsAt: string;
  location: string;
  isImportant: boolean;
  notes: string | null;
};

export type CalendarEventsResponse = {
  events: CalendarEvent[];
};
```

### Fetch events for a visible range

```typescript
const token = process.env.DEVICE_TOKEN!;

export async function fetchCalendarEvents(from: Date, to: Date): Promise<CalendarEvent[]> {
  const params = new URLSearchParams({
    from: from.toISOString(),
    to: to.toISOString(),
  });

  const res = await fetch(`http://localhost:8080/api/v1/calendar/events?${params}`, {
    headers: { Authorization: `Bearer ${token}` },
  });

  if (!res.ok) {
    throw new Error(`calendar fetch failed: ${res.status}`);
  }

  const data: CalendarEventsResponse = await res.json();
  return data.events;
}
```

### Swift (URLSession)

```swift
struct CalendarEventsResponse: Decodable {
    let events: [CalendarEvent]
}

struct CalendarEvent: Decodable {
    let id: String
    let title: String
    let startsAt: Date
    let endsAt: Date
    let location: String
    let isImportant: Bool
    let notes: String?
}

func fetchEvents(from: Date, to: Date, token: String) async throws -> [CalendarEvent] {
    var components = URLComponents(string: "http://localhost:8080/api/v1/calendar/events")!
    components.queryItems = [
        URLQueryItem(name: "from", value: ISO8601DateFormatter().string(from: from)),
        URLQueryItem(name: "to", value: ISO8601DateFormatter().string(from: to)),
    ]
    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw URLError(.badServerResponse)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(CalendarEventsResponse.self, from: data).events
}
```

---

## Errors

| Status | When |
|--------|------|
| `401` | Missing or invalid `Authorization` header |
| `400` | Invalid date range or malformed body |
| `404` | Event ID not found |
| `503` | Postgres unavailable (`GET /health` also fails) |

---

## Local setup

1. Start Postgres: `cd CompanionServer && docker-compose up -d`
2. Copy `.env.example` → `.env` and set `DEVICE_TOKEN`
3. Start server: `swift run CompanionServer`
4. Seed event `evt_abc123` (Team Standup) is inserted on first boot

### Running API tests

```bash
cd CompanionServer
swift test --filter CalendarAPITests
```

Tests use `DATABASE_URL` (default `postgres://postgres:postgres@localhost:5432/companion`) and skip automatically if Postgres is unavailable.

---

## Related docs

- [TASK_API.md](TASK_API.md) — Task REST endpoints
- [STABLE_V1.md](STABLE_V1.md) — WebSocket voice protocol (separate from calendar REST)
- [../CompanionServer/.env.example](../CompanionServer/.env.example) — `DEVICE_TOKEN`, `DATABASE_URL`
