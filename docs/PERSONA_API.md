# Persona API — Character Voices

Personas make the companion speak fully in character (Rocky, Minion, a pirate…)
while keeping everything else — safety rules, serious mode, tools, memories —
intact. A persona **overrides** the `personality` enum from the Config API while
active; clear it and the plain personality tone returns.

**Base URL:** `http://localhost:8080` · **Auth:** same bearer token as everything else
(`Authorization: Bearer <DEVICE_TOKEN>`).

## How personas are defined

One markdown file per character in `CompanionServer/personas/`:

```
personas/
  rocky.md     ← Rocky from Project Hail Mary ("Amaze!", "Question:", "good good")
  minion.md    ← Despicable Me Minion ("Bello!", "banana!")
  grumpy.md    ← comically grumpy robot with a soft heart
  pirate.md    ← swashbuckling captain ("Arrr, matey!")
  wizard.md    ← ancient kindly wizard ("By my beard!")
```

The filename (without `.md`) is the persona name. **Add a character by adding a
file** — no code change, no rebuild; files are read on use. Each file should
cover: speech style, personality, emotion-tool bias (which face emotions to
use), and boundaries (drop the act when the user needs real help).

The active choice persists in `personas/.active` across server restarts.

## Endpoints

### `GET /api/v1/personas`

```json
{ "active": "minion", "available": ["grumpy", "minion", "pirate", "rocky", "wizard"] }
```

`active` is `null` when no persona is set.

### `PUT /api/v1/personas`

Body `{"name": "rocky"}` activates a persona; `{"name": null}` clears it.
Returns the same shape as GET. `400` for unknown names.

**Live update:** if a device session is connected, the change is pushed into it
immediately and applies from the **next turn** — no reconnect needed.

## Testing from the Mac terminal

```bash
TOKEN="<DEVICE_TOKEN from .env>"

# list personas
curl -s http://localhost:8080/api/v1/personas -H "Authorization: Bearer $TOKEN"

# become Rocky
curl -s -X PUT http://localhost:8080/api/v1/personas \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"rocky"}'

# back to normal
curl -s -X PUT http://localhost:8080/api/v1/personas \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":null}'
```

Talk to the robot after the PUT — the very next reply is in character.

## Frontend integration

Render `available` as a character picker; PUT on selection. Pairs with the
Settings page (Config API) but lives on its own endpoint because personas are
file-backed, not part of the Postgres config row.

## Implementation

`PersonaStore.swift` (file loading + active tracking + live-session push),
`PersonaRoutes.swift` (REST), `CompanionPrompt.system(personaInstruction:)`
(prompt injection), `OpenAIRealtimeService.setPersona` (live session.update),
`VoiceSession` (applies on session start, registers for live pushes).
