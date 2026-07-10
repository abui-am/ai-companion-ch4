# Frontend Handoff — 0.1.2 (Personas CRUD + Voice Switching)

Send-to-frontend brief for the Mac app. **Nothing existing breaks** — all
current endpoints return exactly what they returned before. This update adds
persona create/edit/delete endpoints, voice-driven persona switching (which
affects how you should cache state), and cleaner tool-call labels.

**Auth (unchanged):** every request needs `Authorization: Bearer <DEVICE_TOKEN>`.
**Base URL (unchanged):** `http://<server>:8080`.
**Errors (unchanged):** `{"error":{"message":"…"}}` with 400 / 401 / 404.

---

## 1. MUST DO — stop caching the active persona

Users can now switch characters **by voice** ("change persona to grumpy"), so
the active persona changes server-side without the app doing anything.

- Re-fetch `GET /api/v1/personas` every time the persona screen appears
  (or poll while it's visible).
- Don't assume the active persona is whatever the app last PUT.

## 2. NEW — persona editor endpoints (create / read / update / delete)

### Read one persona (for the editor view)

```
GET /api/v1/personas/{name}

200 → { "name": "pirate", "content": "# Captain Saltbeard…", "active": false }
404 → unknown name
```

`content` is the persona's full markdown. `active` tells you whether this is
the live character right now.

### Create or update (same call for both)

```
PUT /api/v1/personas/{name}
Body: { "content": "# My Character\n\nYou are …" }

200 → { "name": "ninja", "content": "…", "active": false }
400 → bad name / empty content / too large
```

Validation rules to mirror in the UI:

| Field | Rule |
| --- | --- |
| `name` (URL path) | letters, numbers, `-`, `_` only — no spaces, no dots |
| `content` | non-empty (not whitespace-only), max 64 KB |

Behavior worth surfacing in the UI:

- Creating a new character = PUT to a name that doesn't exist yet. There is
  no separate "create" call.
- **Saving the currently-active persona updates the robot live** — its next
  spoken turn uses the new text, no restart, no re-activate. A "saved — live
  on next reply" toast is accurate.
- Overwriting a built-in persona (pirate, wizard, …) is allowed; consider a
  confirm dialog.

### Delete

```
DELETE /api/v1/personas/{name}

204 → deleted (no body)
404 → unknown name
```

Deleting the **active** persona automatically clears it (robot falls back to
the plain personality). Refresh the list after delete.

## 3. UNCHANGED — list & activate (what the app already uses)

```
GET /api/v1/personas
200 → { "active": "minion" | null,
        "available": ["chef","detective","grumpy","jokowi","minion","pirate","rocky","vampire","wizard"] }

PUT /api/v1/personas
Body: { "name": "rocky" }   → activate
Body: { "name": null }      → clear (back to default personality)
200 → same shape as GET; 400 for unknown names
```

Only data changed: three new characters ship by default (`chef`, `detective`,
`vampire`). If the picker renders `available` dynamically, zero work.

## 4. Tool-call rendering (conversation history / live events)

If the app renders tool calls (`tool.start` / `tool.done` events and
`GET /conversations/{id}/history`), there are new values — same shapes:

| Tool name | New? | `label` examples | Note |
| --- | --- | --- | --- |
| `persona` | **new tool** | `set: grumpy`, `clear`, `list` | Fires when the user voice-switches characters. Good moment to refresh persona state if the app is open. |
| `emotion` | existing | `happy`, `surprised`, … | **Fixed:** used to be raw JSON like `{"emotion":"happy"}`; now just the emotion name. No code change needed, labels just get cleaner. |
| `move` | existing | `dance`, `spin_left`, `spin_right`, `circle`, `wiggle` + old ones | New action values through the existing path. |

If unknown tool names already render generically, `persona` needs nothing;
otherwise add an icon/case for it.

## 5. Suggested editor screen (if/when you build it)

1. List from `GET /api/v1/personas` — badge the `active` one.
2. Tap → `GET /api/v1/personas/{name}` → markdown editor.
3. Save → `PUT /api/v1/personas/{name}`; if it returned `"active": true`,
   show "live on next reply".
4. "New character" → empty editor, name field with the `[A-Za-z0-9_-]`
   rule, same PUT.
5. Delete → confirm → `DELETE`, then refresh the list.
6. Optional template to prefill for new characters (matches what makes
   personas work well): sections for Identity & backstory, Voice & tone,
   Speech rules, Catchphrase placement, Personality & opinions, Emotion tool
   bias, Move tool bias, Staying in character.

## 6. cURL smoke tests (for the frontend dev)

```bash
TOKEN="<DEVICE_TOKEN>"
H="Authorization: Bearer $TOKEN"
J="Content-Type: application/json"
B="http://localhost:8080/api/v1/personas"

curl -s $B -H "$H"                                        # list
curl -s $B/pirate -H "$H"                                 # read one
curl -s -X PUT $B/ninja -H "$H" -H "$J" \
     -d '{"content":"# Ninja\n\nYou are a silent ninja."}' # create
curl -s -X PUT $B -H "$H" -H "$J" -d '{"name":"ninja"}'   # activate
curl -s -X DELETE $B/ninja -H "$H"                        # delete (also clears active)
```
