# Bracket — Elixir/Phoenix LiveView Design Document

## 1. Product Concept

**Bracket** is a real-time bracket tournament app for friend groups. Anyone creates a bracket for any topic (movies, foods, destinations, whatever), shares a link, and the group votes through matchups together live. No accounts required — join with just a display name.

### Key Differentiators
- **Zero-friction join:** name + link, no signup
- **Real-time sync:** everyone sees bracket updates instantly via LiveView
- **Mobile-first:** designed for phones-in-hand group settings
- **Host control:** creator manages pacing and participants
- **Elixir-native:** each bracket is an isolated OTP process — crash one, the others keep running

### Learning Goals (why Elixir)
This is a port of a working Node.js/Socket.io app. The rewrite exists to demonstrate:
- `Bracket.Game` — pure functions + pattern matching make game logic cleaner and easier to test than JS callbacks
- `BracketServer` (GenServer) — each bracket gets its own process; crash isolation is free
- `Registry + DynamicSupervisor` — OTP's built-in way to spawn/track/supervise processes
- `Phoenix.PubSub + LiveView` — replaces all of Socket.io; real-time UI with zero custom JS

---

## 2. User Flows

### 2.1 Create a Bracket (Host)

```
Landing Page (HomeLive)
→ Enter bracket name + items (individual or bulk paste, min 4 / max 32)
→ Enter host display name
→ Click "Create Bracket"
→ Server seeds bracket, generates hostToken, redirects to /bracket/:id
→ Lobby screen with shareable link + "Start Round 1" button
```

**Validation (client + server):**
- Fewer than 4 items: inline message, Create button disabled
- More than 32 items: inline message, Create button disabled
- Empty bracket name: inline validation, Create button disabled
- Bracket name max 100 chars, item text max 100 chars
- Duplicate items: deduplicated on submit

**Bulk paste:** Textarea accepts newline-separated items. Preview shown before confirming.

**Empty state:** "Add at least 4 items to get started"

**Sharing:** Large share button in lobby (Web Share API on mobile, clipboard fallback). Share text: "Join my bracket: [Name]" + link.

### 2.2 Join a Bracket (Participant)

```
Open /bracket/:id → Enter display name → LiveView calls BracketServer.join/2
→ Lobby screen with participant list
→ Wait for host to start → Vote on matchups
→ See results after each round → Champion screen at end
```

**Late join during active voting:** Late joiners observe the current matchup but cannot vote on it. `eligible_from_matchup` is set to `current_matchup + 1`. Show "Waiting for current matchup to finish..." state.

**Error states:**
- Bracket not found (invalid link): "Bracket not found" screen with link to create new
- Bracket already finished: show final bracket results (read-only)
- Duplicate display name: append number suffix ("Alex 2")
- LiveView disconnect: Phoenix auto-reconnects; on reconnect LiveView re-subscribes and gets full state from BracketServer
- Session lost (browser refresh): participantId stored in localStorage; rejoin with same participantId restores participant state

### 2.3 Voting Flow

```
See two items side-by-side
→ Tap to vote → Can change vote until matchup closes
→ Round closes (all voted OR host closes early OR timer expires) → Winner advances
→ Next matchup OR champion screen if final round
```

**Vote changes:** Tap a choice to vote, tap the other to switch. Server overwrites previous vote in the votes map.

**Tie-breaking:** On a tie, host's vote is the tiebreaker. If host hasn't voted, winner chosen randomly. UI shows "Tie-breaker!"

**Timer UX:** Countdown bar at top. At 10s: warning color + pulse. At 5s: "Last chance!" label. `Process.send_after/3` drives the countdown.

**Missed vote:** When a matchup closes without a participant's vote, show "[Winner] advances" interstitial for 2–3 seconds.

### 2.4 Bracket View (All)

```
Tap "View Bracket" button (any phase)
→ Full-screen panel (mobile) / slide-up panel (desktop) showing bracket tree
→ Current matchup highlighted, past results shown, future slots empty
```

### 2.5 Host Controls

```
During lobby: "Start Round 1" button
During voting: "Close Matchup" button, participant list
After completion: "Restart Bracket" button
Optional: per-round timer (5–300 seconds) via settings gear
```

**Host disconnect:** If the host's LiveView process disconnects for > 30 seconds (tracked via Process.monitor on the host's LiveView pid), participants see "Host disconnected." After 60 seconds, the longest-tenured participant is auto-promoted. A new hostToken is generated and sent via PubSub only to the promoted participant.

**Kick:** Kicked participant's LiveView receives a `{:kicked}` PubSub message and transitions to a "You were removed" screen.

---

## 3. Data Model

All state lives in GenServer processes (one per bracket). No database.

### 3.1 Core Structs (Elixir)

```elixir
defmodule Bracket.Game do
  defstruct [
    :id,                    # string, 8 chars base62
    :name,                  # string, max 100 chars
    :host_token,            # string, UUID v4, authoritative host identity
    :host_lv_pid,           # pid | nil, current LiveView pid of host
    :status,                # :lobby | :active | :finished
    :items,                 # [string], padded to power-of-2 with nil (byes)
    :rounds,                # [%Round{}]
    :current_round,         # integer, 0-indexed
    :current_matchup,       # integer, index within current round
    :participants,          # %{participant_id => %Participant{}}
    :timer_seconds,         # integer | nil
    :timer_ref,             # reference | nil (from Process.send_after)
    :created_at,            # DateTime
    :last_activity_at       # DateTime
  ]
end

defmodule Bracket.Game.Participant do
  defstruct [
    :id,                    # string, nanoid-style from :crypto
    :display_name,          # string, max 30 chars
    :lv_pid,                # pid | nil, current LiveView pid
    :connected,             # boolean
    :joined_at,             # DateTime
    :eligible_from_matchup, # integer | nil (nil = eligible from start)
    :is_host                # boolean
  ]
end

defmodule Bracket.Game.Matchup do
  defstruct [
    :id,       # integer, 0-indexed within round
    :item_a,   # string | nil (nil = bye)
    :item_b,   # string | nil (nil = bye)
    :votes,    # %{participant_id => :a | :b}
    :winner,   # string | nil (set when matchup closes)
    :status    # :pending | :active | :closed
  ]
end

defmodule Bracket.Game.Round do
  defstruct [:matchups]  # [%Matchup{}]
end
```

### 3.2 Bracket Seeding Logic

1. Accept N items (4 ≤ N ≤ 32)
2. Calculate next power of 2: `size = :math.pow(2, ceil(:math.log2(N))) |> trunc()`
3. Shuffle items randomly with `Enum.shuffle/1`
4. Fill remaining slots with `nil` (byes)
5. Build round 0 matchups: `Enum.chunk_every(items, 2)`
6. Any matchup with a bye auto-advances the non-bye item immediately

### 3.3 Round Progression

- All matchups in a round are presented sequentially (one at a time, everyone votes on the same matchup)
- When a matchup closes, winner determined by majority
- Tie-breaking: host vote wins; if host didn't vote, random
- When all matchups in a round close, next round is built from winners
- Final round winner = champion

### 3.4 Bracket Cleanup

- GenServer uses `{:continue, :schedule_cleanup}` on init
- `Process.send_after(self(), :check_activity, @cleanup_interval)` runs every 5 minutes
- If `last_activity_at` > 4 hours ago and status is `:finished` (or > 8 hours regardless), GenServer calls `DynamicSupervisor.terminate_child/2` on itself

---

## 4. Architecture

### 4.1 System Architecture

```
Browser (Phoenix LiveView)
    │  persistent WebSocket (HTTP upgrade)
    │
BracketWeb.Endpoint
    │
BracketWeb.BracketLive  ─── subscribe ──► Phoenix.PubSub ("bracket:{id}")
    │                                              ▲
    │  GenServer call/cast                         │ broadcast
    ▼                                              │
Bracket.BracketServer   ──────────────────────────┘
    │
    ├── state: %Bracket.Game{}
    └── registered in Bracket.Registry under bracket_id
         supervised by Bracket.DynamicSupervisor
```

**Key Elixir concepts exercised:**
- `GenServer` — `BracketServer` holds all bracket state; calls are synchronous, casts are fire-and-forget
- `Registry` — lookup a bracket's GenServer pid by bracket ID (`{:via, Registry, {Bracket.Registry, id}}`)
- `DynamicSupervisor` — spawn/supervise bracket processes, auto-restart on crash
- `Phoenix.PubSub` — broadcast bracket events to all LiveView sessions subscribed to a topic
- `LiveView` — handle real-time UI without custom WebSocket code; `handle_info/2` handles PubSub messages

### 4.2 OTP Supervision Tree

```
Bracket.Application (Supervisor, :one_for_one)
├── Bracket.Registry          (Registry, keys: :unique)
├── Bracket.DynamicSupervisor (DynamicSupervisor)
├── BracketWeb.PubSub         (Phoenix.PubSub, adapter: Phoenix.PubSub.PG2)
└── BracketWeb.Endpoint       (Phoenix endpoint)
```

### 4.3 LiveView Architecture

```
BracketLive (one per browser tab)
    │
    ├── mount/3
    │   ├── subscribe to "bracket:{id}"
    │   ├── call BracketServer.get_state/1 → assigns
    │   └── set up participant_id from session/params
    │
    ├── handle_event("join", %{"name" => name}, socket)
    │   └── call BracketServer.join/3 → broadcast → handle_info updates all tabs
    │
    ├── handle_event("vote", %{"choice" => c, "matchup_id" => mid}, socket)
    │   └── call BracketServer.vote/4 → broadcast
    │
    ├── handle_event("start", _, socket)   [host only]
    ├── handle_event("close_matchup", _, socket)   [host only]
    │
    └── handle_info({:bracket_event, event, game}, socket)
        └── update assigns → LiveView diffs/patches DOM automatically
```

### 4.4 URL / Routing

```elixir
scope "/", BracketWeb do
  pipe_through :browser

  live "/", HomeLive          # create bracket form
  live "/bracket/:id", BracketLive  # join/lobby/voting/champion
end
```

### 4.5 No REST API

Unlike the Node.js version, there is no REST API layer. All create/join/vote actions happen through LiveView events over the same WebSocket. The bracket ID is in the URL — LiveView reads it from `params["id"]` in `mount/3`. This is idiomatic Phoenix.

### 4.6 Host Authentication

- On creation, `BracketServer` generates a `host_token` (`:crypto.strong_rand_bytes(32) |> Base.encode64()`), returned to HomeLive which stores it in the LiveView session
- On mount of BracketLive, the `host_token` is read from the session and passed to BracketServer on join
- Host actions (`start`, `close_matchup`, `kick`, `restart`) verify the `host_token` in the GenServer handle_call
- If the host navigates away and returns (same session cookie), the token is still in their session

### 4.7 Input Sanitization

All user strings are sanitized server-side in `Bracket.Sanitizer`:
- Strip HTML using `Phoenix.HTML.html_escape/1` (renders as text, never raw HTML)
- Trim whitespace
- Enforce length limits
- Deduplicate items

LiveView templates use `<%= %>` by default, which HTML-escapes all output. No `raw/1` is used on user-supplied strings.

### 4.8 State Persistence

No persistence in v1 — bracket state lives only in the GenServer process. If the server restarts, all brackets are lost. This matches the Node.js v1 behavior. On `SIGTERM`, OTP's graceful shutdown calls `terminate/2` on each GenServer; a future v2 could serialize to ETS or a database there.

---

## 5. LiveView Screens / States

`BracketLive` is a single LiveView that renders different UI based on `socket.assigns.phase`:

| Phase | Trigger | View |
|-------|---------|------|
| `:join_form` | URL visit, bracket in `:lobby` or `:active` | Name entry form |
| `:lobby` | After join, bracket status `:lobby` | Participant list + share link; Start button (host only) |
| `:voting` | After `bracket:started` or rejoin mid-vote | Two items + vote buttons; host gets "Close Matchup" |
| `:waiting` | Late joiner during active matchup | "Waiting for current matchup to finish..." |
| `:champion` | After final matchup closes | Winner celebration + full bracket tree |
| `:finished` | Mount on finished bracket | Read-only bracket results |
| `:not_found` | BracketServer not found | "Bracket not found" + link to create new |
| `:kicked` | Receive `{:kicked}` PubSub msg | "You were removed from this bracket" |

---

## 6. Components

### BracketTree
Renders the full bracket as a CSS Grid layout:
- Each round is a column
- Matchups are rows within columns
- Connector lines via CSS pseudo-elements
- Current matchup highlighted
- Winners bold, losers dimmed
- Horizontal scroll with touch panning for large brackets (16–32 items)

### VoteButtons
Two large tap targets side-by-side. After voting:
- Selected option shows checkmark + highlighted border (color AND icon, not color alone)
- Disabled until the next matchup to prevent double-voting

### ParticipantList
Live count + names. Shows connected/disconnected status. Host sees kick buttons.

### TimerBar
Fixed bar at top during timed rounds. Counts down visually. CSS animation for warning state at ≤ 10s.

---

## 7. Tech Stack

| Layer | Technology | Rationale |
|-------|-----------|-----------|
| Framework | Phoenix 1.8 | Batteries-included Elixir web framework |
| Real-time UI | Phoenix LiveView 1.1 | Replaces Socket.io entirely; real-time over WebSocket with server-rendered HTML diffs |
| State | GenServer per bracket | Isolated, crash-recoverable; OTP supervision handles lifecycle |
| Storage | In-memory GenServer state | Brackets are ephemeral; no DB needed for v1 |
| IDs | `:crypto.strong_rand_bytes` + base62 | URL-safe, hard-to-guess bracket IDs |
| CSS | Tailwind (Phoenix default) + DaisyUI | Mobile-first utility classes; DaisyUI components for polish |
| Deployment | Render | Same platform as Node.js version; `mix release` for production |

---

## 8. Architecture Decisions & Tradeoffs

### Decision 1: GenServer per bracket vs. single ETS table
**Choice:** GenServer per bracket
**Rationale:** Natural fit for Elixir. Each bracket is an isolated process — crash isolation is free. Serialized access via GenServer calls eliminates race conditions without locks. Registry + DynamicSupervisor handle lifecycle. Teaching value: demonstrates OTP supervision tree in action.

### Decision 2: LiveView only, no REST API
**Choice:** LiveView events only (no `POST /api/brackets`)
**Rationale:** LiveView handles everything over the same WebSocket. No need for a separate HTTP/JSON layer. Bracket creation goes through a LiveView form → `handle_event` → GenServer. Simpler, more idiomatic Phoenix.

### Decision 3: Sequential matchups
**Choice:** Sequential (everyone votes on the same matchup)
**Rationale:** Creates shared experience. Simpler state machine. Matches Node.js v1 behavior.

### Decision 4: No database for v1
**Choice:** In-memory GenServer state only
**Rationale:** Brackets are ephemeral. Adding Ecto/PostgreSQL would add complexity without user-facing value for v1. GenServer `terminate/2` hook provides a natural serialization point for v2.

### Decision 5: PubSub broadcast on every state change
**Choice:** Broadcast full sanitized game state on every event (not diffs)
**Rationale:** Simpler reasoning. LiveView diffs the DOM anyway — sending the full state to each LiveView lets it compute its own diff. No need to maintain per-subscriber delta logic in the GenServer.

### Decision 6: host_token in LiveView session vs. URL
**Choice:** Session (cookie-backed, not in URL)
**Rationale:** URL params are visible and shareable. The host token must be secret. Phoenix session cookies are signed, preventing tampering.

### Decision 7: participant_id in localStorage
**Choice:** Participant identity stored in localStorage, sent via JS hook on LiveView mount
**Rationale:** Survives browser refreshes and WiFi reconnects. Socket IDs (or LiveView PIDs) change on reconnect; stable participant_id preserves vote history and eligibility.

---

## 9. Deployment Plan

### Local Development
```bash
mix deps.get
mix phx.server   # http://localhost:4000
```

### Production (Render)
```bash
mix release
```

Environment variables:
- `PORT` — HTTP port (default 4000; Render injects this automatically)
- `SECRET_KEY_BASE` — 64-byte hex string (generate with `mix phx.gen.secret`)
- `PHX_HOST` — production hostname for LiveView WebSocket URL verification

**Health check:** `GET /` returns 200 (Phoenix default); optionally add `GET /health` route.

**Scaling note:** Phoenix.PubSub with the PG2 adapter works across a cluster out of the box. For multi-node horizontal scaling, replace with the Redis adapter. No other changes needed — GenServer state would need distributed ETS or a database, but that's a v2 concern.
