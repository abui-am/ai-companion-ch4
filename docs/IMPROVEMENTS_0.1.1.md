# 0.1.1 Improvement Pass — Movement Tricks, Livelier Face, Deep Personas

Everything in this pass, what it was before, what it is now, and why. Four
areas: **movement**, **emotion/face**, **personas**, and **persona
management** (API + voice command). Server: `swift build` clean, 163/163
tests pass. Firmware: compiles for `esp32:esp32:esp32s3` (89% flash, same as
before).

---

## 1. Movement — trick moves (firmware + server)

### Before vs after

| | Before | After |
| --- | --- | --- |
| Patterns | `stroll`, `forward`, `backward`, `turn_left`, `turn_right`, `stop` | + `spin_left`, `spin_right`, `circle`, `wiggle`, `dance` |
| "Do a trick" | Nothing mapped — the model could only stroll | Full `dance` routine: spin → forward → backward → wiggle → counter-spin |
| Circular motion | Impossible (only straight bumps and in-place pivots) | `circle` arcs by slowing the inner wheel instead of stopping it |
| Max `duration_ms` | 2000 ms | 4000 ms (spins/arcs need longer than bumps) |

### What each new pattern does (firmware `motor_drive.cpp`)

| Pattern | Behavior | Default duration |
| --- | --- | --- |
| `spin_left` / `spin_right` | Long in-place pivot — roughly a full rotation on a smooth desk | `MOTOR_SPIN_MS` (1400 ms) |
| `circle` | Arc drive: outer wheel at cruise PWM (150), inner wheel slowed to `MOTOR_CIRCLE_INNER_PWM` (60) — sweeps a small loop | `MOTOR_CIRCLE_MS` (2600 ms) |
| `wiggle` | 3 quick left-right shimmy cycles (`MOTOR_WIGGLE_CYCLES` × `MOTOR_WIGGLE_STEP_MS` 180 ms) — reads as a happy tail-wag | fixed |
| `dance` | The showpiece: `spin_right` → pause → forward bump → pause → backward bump → pause → `wiggle` → `spin_left` | ~6 s total |

Why it's built this way:

- **Every step keeps the existing ramp + stop-request machinery.** The
  DRV8833 shares a 5 V rail with the speaker amp, so all new moves reuse
  `rampTo()`/`rampStop()` (no instant full-duty steps → no brownouts), and
  every segment of `dance`/`wiggle` checks `s_stopRequested`, so a spoken
  "stop" or a new command still interrupts a trick mid-routine, exactly like
  it interrupted a stroll before.
- **Tunable without code changes:** all timings/duties are new `config.h`
  defines (`MOTOR_SPIN_MS`, `MOTOR_CIRCLE_MS`, `MOTOR_CIRCLE_INNER_PWM`,
  `MOTOR_WIGGLE_*`, `MOTOR_TRICK_PAUSE_MS`) — tune spin distance per desk
  surface by editing one number.
- **Validated end-to-end:** the server's `CmdRouter` whitelist and
  `MotionAgent` enum were extended in lockstep with the firmware, so an LLM
  hallucinating a pattern still gets rejected server-side.

### How the model picks tricks (prompt + tool description)

The `move` tool description and the system prompt's Move section now map
phrases to actions, including STT-noise phrasing:

| User says | Action |
| --- | --- |
| "spin", "spin around", "do a spin" | `spin_left` / `spin_right` |
| "go in a circle", "run a lap", "circle around" | `circle` |
| "do a trick", "dance", "show me a move", "do something cool" | `dance` |
| big celebratory moment (unprompted, max once per conversation) | `wiggle` |

The unprompted-`wiggle` rule is new: the robot may fire one happy shimmy on
genuinely big user wins, which makes the body language feel alive rather than
strictly command-driven.

---

## 2. Emotion & face — shock reactions and livelier holds

### Prompt: user bombshells now force a face change

Before, decision-ladder rule 5 (`surprised`) was written around **the
robot's own reveals** ("plot twist, shocking fact, huge number"). If the
*user* said something shocking, only the generic rule-2 feelings mirror
("I'm shocked") caught it. Now rule 5 explicitly fires in **both
directions** — the moment the user drops "guess what happened!", a dramatic
confession, wild gossip, or an out-of-nowhere announcement, the face must
flip to `surprised` in that same turn, and an unchanged face is called out
as a bug (same forcing language that made rule 2 reliable).

### Firmware: emotion animations (face_display.cpp)

| Emotion | Before | After | Why |
| --- | --- | --- | --- |
| `surprised` | Static big round eyes + flashing "!" | Opens with a 700 ms **shock tremble** (horizontal flicker), then settles into the frozen wide-eyed stare | A jolt reads as *shocked*; a static stare read as merely attentive |
| `happy` | One `anim_laugh()` at onset, then still for the rest of the hold | Re-laughs every 2.8–4.6 s for the whole hold | An 8 s hold no longer freezes after the first second |
| `love` | Happy mood + hearts overlay only | + flirty **winks**, alternating eyes, every 1.8–3.2 s | Hearts + winks is unmistakably "love", not just "happy with decoration" |
| `excited` / `confused` | Already had repeating animations | unchanged | — |

All three additions run through the existing `tickFaceBehavior()` per-frame
tick (main-loop only, no new tasks, no extra I2C traffic — they piggyback on
the same RoboEyes frame flush).

---

## 3. Personas — total character takeover

### The character lock (CompanionPrompt.personaBlock)

Before, an active persona was injected under one line: *"Active persona —
stay fully in character (overrides the default tone)"*. The Botchill identity
paragraph still sat above it, and nothing told the model how to answer "are
you an AI?" or how to behave in serious mode without dropping the voice.

Now the persona block declares a **total takeover** with explicit hard rules:

- The persona IS the entire identity; Botchill ceases to exist while active.
- Never break character, never say "roleplay/persona/prompt/instructions",
  never speak as a generic assistant.
- "What are you?" gets answered **in character** (each persona file ships its
  own canned answer — the robot chassis is explained inside the fiction).
- Every tool call — search preambles, task confirmations, move narrations —
  is voiced through the character.
- Serious moments are handled **as the character would** (quieter, plainer,
  fully present) instead of falling back to a generic assistant voice. Safety
  behavior is kept; the voice never is dropped.

### Persona files — before vs after

| File | Before | After |
| --- | --- | --- |
| `pirate.md` | 30 lines, 4 sections | ~100 lines: named identity (Captain Saltbeard), backstory & running gags, strict catchphrase placement, opinions, full emotion map, trick-move bias, character lock |
| `wizard.md` | 30 lines | ~90 lines: Eldrin the Evergreen, Great Library lore, Percival the raven, catchphrase rules, emotion + move bias, character lock |
| `grumpy.md` | 31 lines | ~100 lines: Grumbles Unit G-247, Reginald-the-toaster rivalry, "GET OFF MY LAWN!" placement, rare-`happy`-by-design, denied-wiggle gag, character lock |
| `minion.md` | 66 lines (already detailed) | + named identity (Dave), backstory (Kevin, 34 bananas, the stapler incident), mech-suit move bias, character lock |
| `rocky.md` | 68 lines (already detailed) | + Eridian backstory, maintenance-log gag, engineering-demo move bias, character lock |
| `jokowi.md` | 78 lines (already detailed) | + blusukan-framed move bias ("kunjungan kerja"), strengthened caricature guardrails kept, character lock |

Every persona now ends with a **"Staying in character (absolute)"** section
and a **"Move tool bias"** section wired to the new tricks — so `dance` is
"BATTLE MANEUVERS!" for the pirate, "a LEVITATION CHARM" for the wizard, a
loudly-protested-then-flawless routine for Grumbles, and "full mobility test
sequence" for Rocky. Each persona also biases `surprised` to fire instantly
on user bombshells, reinforcing the prompt-level rule per character.

### Three brand-new characters

| File | Character | Flavor |
| --- | --- | --- |
| `detective.md` | Ace Marlowe, hard-boiled noir private eye | Rain-streaked narration, "Case closed.", the roomba that spiraled; runs cool (`neutral` default) so expressions land harder |
| `vampire.md` | Count Voltberg III, 900-year-old harmless vampire | "BEHOLD!", cape-swirl drama, mango juice as "blood of the orchard", nemesis: the desk lamp; explicitly fangless/harmless |
| `chef.md` | Chef Aurelio Fuoco, fiery five-star kitchen legend | "ANDIAMO!", "IT'S RAW!" (max 2×), "ORDER UP!", kitchen-brigade framing, quality-obsession that roasts situations, never the user |

The three were chosen to cover expressive ranges the existing six don't:
low-key deadpan (detective), maximal theatrical drama (vampire), and
high-energy loud passion (chef) — so the emotion/motion systems get exercised
across the whole spectrum.

---

## 4. Persona management — REST CRUD + voice switching

### New endpoints (for the Mac app)

The API previously only listed and activated personas; files had to be edited
by hand on the server. Full CRUD now (details + curl examples in
`docs/PERSONA_API.md`):

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/v1/personas/{name}` | Read one persona's markdown (`{name, content, active}`) — editor view |
| PUT | `/api/v1/personas/{name}` | Create or update (`{"content": "…"}`); name validated (path traversal blocked), content non-empty, ≤ 64 KB |
| DELETE | `/api/v1/personas/{name}` | `204`; deleting the active persona clears it first |

Key behavior: **saving the currently-active persona pushes the new text into
every live session immediately** (same mechanism activation already used), so
editing a character in the Mac app changes the robot's next spoken turn
without a reconnect.

### Voice command: "change persona to grumpy"

New `PersonaAgent` sub-agent (tool name `persona`, actions `set` / `clear` /
`list`) registered alongside move/emotion, plus a prompt section teaching the
model to catch switch phrasing — including STT manglings like "persoso",
"persina", "person" and Indonesian phrasing ("jadi vampire", "ganti karakter
ke chef"). Name resolution is fuzzy: exact → case/separator-insensitive →
unique prefix/substring ("grump" → grumpy, "the pirate" → pirate); ambiguous
or unknown names return the available list so the robot can offer choices
instead of guessing. Switches go through the same `PersonaStore`, so a voice
switch persists across restarts and shows up in `GET /api/v1/personas`.

The prompt also scripts the handover: the current character finishes the turn
with one short in-character goodbye, and the new character owns the next turn
(persona pushes take effect on the next model turn by design).

---

## 5. Audit pass — holes found and fixed

A second review pass over the whole change (and adjacent code) found and
fixed these:

| # | Hole / bad code | Where | Fix | Why it mattered |
| --- | --- | --- | --- | --- |
| 1 | `MOTOR_CIRCLE_INNER_PWM 60` was **below the static-friction floor** (`MOTOR_PWM_MIN 100`) — the inner wheel would stall, and `rampTo()`'s min-floor caused a duty jump (100 → 60) when the hold started | `config.h` | Raised to 100 (= the floor) with a comment explaining the stall-vs-arc tradeoff | The "circle" would have been a jerky pivot around a dragged wheel instead of an arc |
| 2 | `wiggle()` **slammed both wheels straight into reverse** between shimmy steps — `rampTo()` scales toward the new target only, it never passes through zero | `motor_drive.cpp` | 40 ms coast (`setDrive(0,0)`) between direction flips | Instant H-bridge reversal spikes the 5 V rail shared with the speaker amp — brownout risk mid-speech |
| 3 | `ConversationToolCallBuilder.label()` returned **raw JSON** for `emotion` calls, and would have for `persona` calls | `ConversationToolCallBuilder.swift` | `emotion` → the emotion name; `persona` → `"set: grumpy"` / `"clear"` / `"list"` | The Mac app's tool-call UI showed `{"emotion":"happy"}` instead of `happy` (pre-existing bug) |
| 4 | Botchill's hidden layer (the Wowo bit) sits **above** the persona block in the prompt and could leak into any character | `CompanionPrompt.personaBlock` | Persona block now explicitly disables the hidden layer | A pirate suddenly ranting about Wakanda politics would break the character illusion |
| 5 | The new persona CRUD endpoints had **zero route-level tests** | Tests | New `PersonaAPITests` (7 tests, no DB needed): auth rejection, CRUD round-trip, activate/clear, 400 on bad name/empty content, delete-active-clears, 404s | The Mac app contract (status codes, JSON shapes) was unverified |
| 6 | The prompt regression test didn't cover the new sections | `CmdRouterTests` | Asserts tricks (`dance`, `spin_left`, `circle`, `wiggle`), the persona tool, the shock rule, and a new character-lock test (`NEVER break character`, stock personality line replaced) | A future prompt refactor could silently drop the new behavior |
| 7 | Personas only *instructed* the model to ignore Botchill/Wowo — the text was still in the prompt (and "still Botchill" sat in the shared web_search section) | `CompanionPrompt` | With a persona active, the Botchill intro + hidden layer + personality line are **omitted from the prompt entirely** — the persona block IS the identity; the web_search tone line no longer names Botchill; test asserts a persona prompt contains no "Botchill"/"Wowo"/"Wakanda" | Instructed-to-ignore text can still leak; absent text cannot |
| 8 | Emotion changes were invisible when they mattered most: the full-screen "You said:" transcript holds the OLED for 5 s at the start of a reply — exactly when the emotion tool fires | `face_display.cpp` | Setting a non-neutral emotion dismisses the transcript screen immediately, so the face (and its corner mark) shows the reaction | The user reported expression changes were "hard to tell because the text takes over" |

Also verified (no changes needed):

- **Firmware command path**: `ws_session.cpp` has no pattern whitelist — it
  forwards to `motorHandleCommand`/`faceDisplaySetEmotion`, which handle
  unknowns safely, so old firmware + new server (or vice versa) degrades
  gracefully.
- **Server validation path**: every LLM tool call goes through
  `DeviceCommandGateway.send` → `CmdRouter.validate` — hallucinated patterns
  and out-of-range durations are rejected before reaching the device.
- **Persona live-push wiring**: `VoiceSession` attaches the store on start,
  applies the active persona from `applyUserConfig`, detaches on disconnect;
  `PersonaStore.setActive`/`save` push `session.update` into every attached
  session. Voice switches, API switches, and API edits all take the same path.
- **Emotion vs speaking face precedence** (firmware `applyFace`): an active
  emotion overrides the mode face (`FACE_SPEAKING` etc.) for its hold
  duration, then decays back — so the face can flip to `surprised` mid-reply
  and return to the talking face automatically.
- **Trick interruption**: every `dance`/`wiggle` segment checks
  `s_stopRequested`, so "stop" (or any new move command) still halts a trick
  mid-routine.

## 6. Verification

| Check | Result |
| --- | --- |
| `swift build` | clean |
| `swift test` (needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for XCTest) | 171/171 pass |
| New tests | trick patterns in `CmdRouterTests` + `MotionAgentTests`; `PersonaAgentTests` (fuzzy resolution, set/clear/list, store CRUD, path-traversal rejection, active-clear-on-delete); `PersonaAPITests` (route-level HTTP contract) |
| `arduino-cli compile --fqbn esp32:esp32:esp32s3 CompanionFirmware` | compiles, 89% flash / 23% RAM (unchanged headroom) |

### Files touched

| Area | Files |
| --- | --- |
| Firmware | `config.h` (trick tunables), `motor_drive.cpp` (5 new patterns), `face_display.cpp` (3 emotion animation upgrades) |
| Server | `CmdRouter.swift`, `MotionAgent.swift`, `CompanionPrompt.swift`, `PersonaStore.swift`, `PersonaRoutes.swift`, `PersonaAgent.swift` (new), `CompanionServerApp.swift` |
| Personas | 6 rewritten/expanded, 3 new (`detective`, `vampire`, `chef`) |
| Tests | `CmdRouterTests`, `MotionAgentTests`, `PersonaAgentTests` (new) |
| Docs | `PERSONA_API.md` (CRUD + voice switching), this file |
