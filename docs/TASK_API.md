# Task API — Frontend Integration

REST endpoints for the task list view. Tasks are stored in Postgres and returned as JSON matching the view model.

**Base URL:** `http://localhost:8080` (CompanionServer default)

**Auth:** Same bearer token as WebSocket (`DEVICE_TOKEN` in `.env`).

```
Authorization: Bearer <DEVICE_TOKEN>
```

---

## Reminders

When a task is created or updated with a `dueAt`, CompanionServer schedules a reminder at `dueAt − notifications.remindBeforeMinutes` (from [CONFIG_API.md](CONFIG_API.md)). At fire time:

- Botchill (ESP32) — if connected and idle: `surprised` face + spoken reminder ([EMOTION_API.md](EMOTION_API.md))
- **Mac app** — APNs push to registered devices ([PUSH_API.md](PUSH_API.md))

Gated by `notifications.taskReminders`. Completing or deleting a task cancels its reminder.

---

## Task object

```json
{
  "id": "task_xyz",
  "title": "Finish report",
  "completed": false,
  "dueAt": "2026-07-08T17:00:00Z",
  "notes": null
}
```

| Field | Type | Notes |
|-------|------|-------|
| `id` | string | Stable ID, prefix `task_` |
| `title` | string | Task title |
| `completed` | boolean | Whether the task is done |
| `dueAt` | string (ISO 8601 UTC) \| null | Optional due date |
| `notes` | string \| null | Optional notes |

---

## Endpoints

### List tasks

```
GET /api/v1/tasks?completed=<true|false>
```

The `completed` query parameter filters by completion status. **When omitted, defaults to `false`** — only incomplete tasks are returned.

| Query | Result |
|-------|--------|
| (omitted) | Incomplete tasks only (`completed=false`) |
| `completed=false` | Incomplete tasks only |
| `completed=true` | Completed tasks only |

Tasks are ordered by `dueAt` ascending (null due dates last), then by creation time.

**Response `200`:**

```json
{
  "tasks": [
    {
      "id": "task_xyz",
      "title": "Finish report",
      "completed": false,
      "dueAt": "2026-07-08T17:00:00Z",
      "notes": null
    }
  ]
}
```

**Example — default (incomplete tasks):**

```bash
curl -s \
  -H "Authorization: Bearer $DEVICE_TOKEN" \
  "http://localhost:8080/api/v1/tasks"
```

**Example — completed tasks:**

```bash
curl -s \
  -H "Authorization: Bearer $DEVICE_TOKEN" \
  "http://localhost:8080/api/v1/tasks?completed=true"
```

### Get one task

```
GET /api/v1/tasks/{id}
```

**Response `200`:** single Task object (same shape as list items).

**Response `404`:** task not found.

### Create task

```
POST /api/v1/tasks
Content-Type: application/json
```

**Request body:**

```json
{
  "title": "Buy groceries",
  "dueAt": "2026-07-09T12:00:00Z",
  "notes": "Milk and eggs"
}
```

`dueAt` and `notes` are optional. New tasks are always created with `completed: false`.

**Response `200`:** created Task object (server assigns `id`).

**Response `400`:** empty title.

### Update task

```
PATCH /api/v1/tasks/{id}
Content-Type: application/json
```

**Request body** (all fields optional — only provided fields are updated):

```json
{
  "title": "Finish report (revised)",
  "completed": true,
  "dueAt": null,
  "notes": "Updated notes"
}
```

Send `"dueAt": null` or `"notes": null` to clear those fields.

**Response `200`:** updated Task object.

**Response `404`:** task not found.

**Response `400`:** empty title.

### Delete task

```
DELETE /api/v1/tasks/{id}
```

**Response `204`:** task deleted.

**Response `404`:** task not found.

---

## Frontend examples

### TypeScript types

```typescript
export type Task = {
  id: string;
  title: string;
  completed: boolean;
  dueAt: string | null;
  notes: string | null;
};

export type TasksResponse = {
  tasks: Task[];
};
```

### Fetch incomplete tasks (default)

```typescript
const token = process.env.DEVICE_TOKEN!;

export async function fetchIncompleteTasks(): Promise<Task[]> {
  const res = await fetch("http://localhost:8080/api/v1/tasks", {
    headers: { Authorization: `Bearer ${token}` },
  });

  if (!res.ok) {
    throw new Error(`task fetch failed: ${res.status}`);
  }

  const data: TasksResponse = await res.json();
  return data.tasks;
}

export async function fetchCompletedTasks(): Promise<Task[]> {
  const res = await fetch("http://localhost:8080/api/v1/tasks?completed=true", {
    headers: { Authorization: `Bearer ${token}` },
  });

  if (!res.ok) {
    throw new Error(`task fetch failed: ${res.status}`);
  }

  const data: TasksResponse = await res.json();
  return data.tasks;
}
```

### Mark task complete

```typescript
export async function completeTask(id: string): Promise<Task> {
  const res = await fetch(`http://localhost:8080/api/v1/tasks/${id}`, {
    method: "PATCH",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ completed: true }),
  });

  if (!res.ok) {
    throw new Error(`task update failed: ${res.status}`);
  }

  return res.json();
}
```

### Swift (URLSession)

```swift
struct TasksResponse: Decodable {
    let tasks: [Task]
}

struct Task: Decodable {
    let id: String
    let title: String
    let completed: Bool
    let dueAt: Date?
    let notes: String?
}

func fetchIncompleteTasks(token: String) async throws -> [Task] {
    var request = URLRequest(url: URL(string: "http://localhost:8080/api/v1/tasks")!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw URLError(.badServerResponse)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(TasksResponse.self, from: data).tasks
}
```

---

## Errors

| Status | When |
|--------|------|
| `401` | Missing or invalid `Authorization` header |
| `400` | Invalid `completed` filter, empty title, or malformed body |
| `404` | Task ID not found |
| `503` | Postgres unavailable (`GET /health` also fails) |

---

## Local setup

1. Start Postgres: `cd CompanionServer && docker-compose up -d`
2. Copy `.env.example` → `.env` and set `DEVICE_TOKEN`
3. Start server: `swift run CompanionServer`
4. Seed task `task_xyz` (Finish report) is inserted on first boot

### Running API tests

```bash
cd CompanionServer
swift test --filter TaskAPITests
```

Tests use `DATABASE_URL` (default `postgres://postgres:postgres@localhost:5432/companion`) and skip automatically if Postgres is unavailable.

---

## Related docs

- [PROFILE_API.md](PROFILE_API.md) — Profile and focus time REST endpoints
- [CALENDAR_API.md](CALENDAR_API.md) — Calendar REST endpoints
- [CONFIG_API.md](CONFIG_API.md) — Settings REST endpoints
- [EMOTION_API.md](EMOTION_API.md) — OLED face via `device_command` (reminders use `surprised`)
- [PUSH_API.md](PUSH_API.md) — Mac app APNs reminder notifications
- [STABLE_V1.md](STABLE_V1.md) — WebSocket voice protocol
- [../CompanionServer/.env.example](../CompanionServer/.env.example) — `DEVICE_TOKEN`, `DATABASE_URL`
