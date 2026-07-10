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
  rocky.md      ← Rocky from Project Hail Mary ("Amaze!", "Question:", "good good")
  minion.md     ← Despicable Me Minion "Dave" ("Bello!", "banana!")
  grumpy.md     ← Grumbles, comically grumpy antique robot ("Ugh. Fine.")
  pirate.md     ← Captain Saltbeard, swashbuckling captain ("Arrr, matey!")
  wizard.md     ← Eldrin the Evergreen, ancient kindly wizard ("By my beard!")
  jokowi.md     ← affectionate calm-statesman caricature ("kerja, kerja, kerja")
  detective.md  ← Ace Marlowe, hard-boiled noir private eye ("Case closed.")
  vampire.md    ← Count Voltberg, dramatic harmless vampire ("BEHOLD!")
  chef.md       ← Chef Fuoco, fiery five-star kitchen legend ("ANDIAMO!")
```

The filename (without `.md`) is the persona name. **Add a character by adding a
file** — no code change, no rebuild; files are read on use. The strongest
personas define, in order:

| Section | What it does |
| --- | --- |
| Identity & backstory | Who the character IS — running gags, history, named side characters |
| Voice & tone | How the TTS delivery should feel (pace, volume, texture) |
| Speech rules (strict) | Vocabulary, framing metaphors, addressing the user |
| Catchphrase placement (strict) | Exactly when each catchphrase may fire (prevents catchphrase spam) |
| Personality & opinions | Stable opinions/quirks so the character stays consistent |
| Emotion tool bias | Which OLED face to pull in which situation, per character |
| Move tool bias | How the character narrates `stroll`/`dance`/`spin_*`/`circle`/`wiggle` tricks |
| Staying in character | Absolute character lock + how serious moments are handled in-voice |

The active choice persists in `personas/.active` across server restarts.

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/v1/personas` | List available personas + which is active |
| PUT | `/api/v1/personas` | Activate (`{"name":"rocky"}`) or clear (`{"name":null}`) |
| GET | `/api/v1/personas/{name}` | Read one persona's full markdown content |
| PUT | `/api/v1/personas/{name}` | Create or update a persona file (body: `{"content":"…"}`) |
| DELETE | `/api/v1/personas/{name}` | Delete a persona file (clears it first if active) |

### `GET /api/v1/personas`

```json
{ "active": "minion", "available": ["chef", "detective", "grumpy", "jokowi", "minion", "pirate", "rocky", "vampire", "wizard"] }
```

`active` is `null` when no persona is set.

### `PUT /api/v1/personas`

Body `{"name": "rocky"}` activates a persona; `{"name": null}` clears it.
Returns the same shape as GET. `400` for unknown names.

**Live update:** if a device session is connected, the change is pushed into it
immediately and applies from the **next turn** — no reconnect needed.

### `GET /api/v1/personas/{name}` — read one persona

```json
{ "name": "pirate", "content": "# Captain Saltbeard…", "active": false }
```

`404` when the file doesn't exist. Use this to populate an editor view.

### `PUT /api/v1/personas/{name}` — create or update

Body: `{ "content": "# My Character\n\nYou are …" }`. Creates
`personas/<name>.md` if missing, overwrites it if present, and returns the
same shape as the GET-by-name. Rules:

- `name`: letters, numbers, `-`, `_` only (path traversal is rejected) → `400`
- `content`: must be non-empty, max 64 KB → `400`
- **Editing the active persona pushes the new text into live sessions
  immediately** — next spoken turn uses the updated character.

### `DELETE /api/v1/personas/{name}`

`204` on success, `404` for unknown names. Deleting the active persona clears
it first (the robot falls back to the plain personality tone).

## Switching by voice (persona tool)

The realtime LLM has a `persona` tool, so the user can switch characters by
just talking to the robot — no app needed:

| Say | What happens |
| --- | --- |
| "change persona to grumpy" / "switch to the pirate" / "be the minion" | `persona(action=set, name=…)` — new character from the next reply |
| "jadi vampire" / "ganti karakter ke chef" | same, Indonesian phrasing works too |
| "what characters can you do?" | `persona(action=list)` — speaks the available names |
| "stop the act" / "back to normal" / "be yourself" | `persona(action=clear)` |

Name matching is STT-noise tolerant ("persoso"/"persina" → persona; "grump" →
grumpy; "the pirate" → pirate). The current character finishes the turn with a
short in-character handover, then the new character owns the conversation.
Voice switches go through the same `PersonaStore`, so they persist and show up
in `GET /api/v1/personas` for the Mac app.

## Testing from the Mac terminal

```bash
TOKEN="<DEVICE_TOKEN from .env>"

# list personas
curl -s http://localhost:8080/api/v1/personas -H "Authorization: Bearer $TOKEN"

# become Rocky
curl -s -X PUT http://localhost:8080/api/v1/personas \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"rocky"}'

# read one persona's markdown
curl -s http://localhost:8080/api/v1/personas/pirate -H "Authorization: Bearer $TOKEN"

# create/update a custom persona
curl -s -X PUT http://localhost:8080/api/v1/personas/ninja \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"content":"# Ninja\n\nYou are a silent, dramatic ninja…"}'

# delete it
curl -s -X DELETE http://localhost:8080/api/v1/personas/ninja \
  -H "Authorization: Bearer $TOKEN"

# back to normal
curl -s -X PUT http://localhost:8080/api/v1/personas \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":null}'
```

Talk to the robot after the PUT — the very next reply is in character.

## Frontend integration (Mac app)

- **Picker:** `GET /api/v1/personas` → render `available` as the character
  list, highlight `active`; `PUT /api/v1/personas` with `{"name": …}` on tap.
- **Editor:** `GET /api/v1/personas/{name}` → markdown into a text view;
  `PUT /api/v1/personas/{name}` with `{"content": …}` on save. New characters
  are the same PUT with a new name — no separate create call.
- **Delete:** `DELETE /api/v1/personas/{name}`; expect `204`, refresh the list.
- All responses are JSON except DELETE (`204 No Content`). Errors are standard
  Hummingbird `{"error":{"message":"…"}}` with 400/401/404.

## Implementation

`PersonaStore.swift` (file CRUD + active tracking + live-session push),
`PersonaRoutes.swift` (REST), `PersonaAgent.swift` (voice-command tool),
`CompanionPrompt.system(personaInstruction:)` (prompt injection + character
lock), `OpenAIRealtimeService.setPersona` (live session.update),
`VoiceSession` (applies on session start, registers for live pushes).
