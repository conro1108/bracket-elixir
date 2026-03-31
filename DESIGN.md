# Bracket — Elixir/Phoenix LiveView Design Document

## 1. Product Concept

**Bracket** is a real-time bracket tournament app for friend groups. Anyone creates a bracket for any topic (movies, foods, destinations, whatever), shares a link, and the group votes through matchups together live. No accounts required — join with just a display name.

### Key Differentiators
- **Zero-friction join:** name + link, no signup
- **Real-time sync:** everyone sees bracket updates instantly via LiveView
- **Mobile-first:** designed for phones-in-hand group settings
- **Host control:** creator manages pacing and participants
- **Elixir-native:** each bracket is an isolated OTP process — crash one, the others keep running
- **Anonymous voting:** only aggregate counts are broadcast; individual votes stay in the GenServer

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
→ Server seeds bracket, generates host_token, redirects to /bracket/:id
→ host_token stored in signed Phoenix session (cookie), NOT in URL
→ Lobby screen with shareable link + host recovery URL + "Start Round 1" button
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

**Host recovery URL:** After creation, show a "Host recovery link" in the lobby (collapsible). This is `/bracket/:id/host?token=<host_token>`. Visiting it restores host privileges if the cookie is lost. The host should bookmark this before closing the tab.

**Rate limiting:** Max 10 brackets created per IP per hour (enforced in `HomeLive.handle_event("create", ...)` via ETS counter). Max 1000 concurrent brackets enforced by `DynamicSupervisor`'s `max_children: 1000` option.

### 2.2 Join a Bracket (Participant)

```
Open /bracket/:id → LiveView connected? check (skeleton screen while static render)
→ Enter display name → LiveView calls BracketServer.join/2
→ Server generates participant_id, stores in signed session
→ Lobby screen with participant list
→ Wait for host to start → Vote on matchups
→ See results after each round → Champion screen at end
```

**Loading states:**
- **LiveView connecting:** While `not connected?(socket)`, render a skeleton screen with a spinner. This covers the gap between static render and WebSocket connection.
- **Vote progress:** Show "X of Y voted" (Y = eligible voters only) during active matchups.
- **Matchup transitions:** Show "[Winner] advances" interstitial for 2 seconds before auto-advancing.

**Reconnection states:**
- **< 5 seconds:** Subtle pulsing indicator in the header. Vote buttons remain enabled.
- **5–30 seconds:** Overlay banner: "Reconnecting... your votes are saved." Disable vote buttons.
- **> 30 seconds:** Full-screen "Connection lost" state with a "Try Again" button. Implemented via JS hook listening to `phx:disconnect`/`phx:reconnect` events.
- On reconnect: LiveView re-mounts, calls `BracketServer.get_state/1`, restores participant state from signed session.

**Late join during active voting:** Late joiners observe the current matchup but cannot vote on it. `eligible_from_matchup` is set to `current_matchup + 1`. Show: the current matchup items (read-only, no vote buttons), vote progress ("X of Y voted"), participant list, "View Bracket" button. Message: "You joined mid-round. You can vote starting next matchup."

**Error states:**
- Bracket not found (invalid link): "Bracket not found" screen with link to create new
- Bracket already finished: show final bracket results (read-only)
- Bracket full (> 50 participants): "This bracket is full" screen
- Duplicate display name: append number suffix ("Alex 2")

### 2.3 Voting Flow

```
See two items side-by-side
→ Tap to vote → Can change vote until matchup closes
→ Round closes (all voted OR host closes early OR timer expires) → Winner advances
→ Next matchup OR champion screen if final round
```

**Vote changes:** Tap a choice to vote, tap the other to switch. Both buttons remain active until the matchup closes (never disabled during an active matchup). After voting, the selected button shows a checkmark + highlighted border (color AND icon, not color alone). Tapping the other option switches the vote.

**Anonymous voting:** Individual votes (who voted for what) are NEVER broadcast to clients. PubSub broadcasts contain only aggregate counts: `vote_count_a`, `vote_count_b`, `total_eligible`. Individual votes remain in GenServer state only (for tie-breaking). This prevents social pressure in friend groups.

**Tie-breaking:** On a tie, host's vote is the tiebreaker. If host hasn't voted, winner chosen randomly. UI shows "Tie-breaker!"

**Timer UX:** Countdown bar at top. At 10s: warning color + pulse (with text "10 seconds left" for accessibility). At 5s: "Last chance!" label. `Process.send_after/3` drives the countdown. Timer ref is always cancelled when a matchup closes (by any means) before starting the next timer.

**Missed vote:** When a matchup closes without a participant's vote, show "[Winner] advances" interstitial for 2–3 seconds before auto-advancing.

### 2.4 Bracket View (All)

```
Tap "View Bracket" button (any phase: lobby, voting, champion)
→ Mobile: full-screen panel, only X button dismisses it (no drag-to-dismiss)
→ Desktop: slide-up panel, X button or Escape to close
→ Current matchup highlighted, past results shown, future slots empty
```

**Mobile interaction design:**
- `touch-action: pan-x` on bracket container allows horizontal scroll without triggering browser swipe-back
- `overscroll-behavior: contain` prevents pull-to-refresh conflict
- No drag-to-dismiss to avoid conflict with horizontal scroll
- Browser back button closes the panel: `pushState` on open, `popstate` listener closes it
- Minimum 44×44px touch target for the X close button

**Focus trap:** When panel opens, focus moves inside it. Tab and Shift+Tab cycle within the panel. Escape closes it. `aria-modal="true"`, `role="dialog"`.

### 2.5 Host Controls

```
During lobby: "Start Round 1" button + optional timer settings gear icon
During voting: "Close Matchup" button, participant list with kick buttons
After completion: "Restart Bracket" button
```

**Timer settings:** Gear icon in host's header. Available in lobby and between matchups (not during an active vote). Single control: timer toggle + slider for 5–300 seconds. Default: off. Once a matchup starts with a timer active, it cannot be changed until the next matchup. Timer setting is visible to all participants in the lobby so they know what to expect.

**Restart Bracket flow:**
- Host clicks "Restart Bracket" on the champion screen
- GenServer resets `status` to `:lobby`, clears all rounds and votes, re-shuffles items, resets all participant `eligible_from_matchup` to nil
- All LiveViews receive a `:bracket_restarted` broadcast and transition to `:lobby` phase
- Bracket ID stays the same (URL unchanged)
- Disconnected participants can rejoin via the same link

**Kick feedback:** Kicked participant's LiveView receives `{:kicked}` PubSub message and transitions to "You were removed from this bracket" screen.

**Host disconnection and transfer:**
1. GenServer monitors the host's LiveView PID via `Process.monitor/1`
2. When host reconnects (any `join` call with host_token), the GenServer demonitors the old PID ref and re-monitors the new PID, cancelling any pending transfer timer
3. On `:DOWN` message: start a 30-second timer (`Process.send_after(self(), :host_transfer_warning, 30_000)`)
4. Participants see "Host disconnected" countdown
5. If host does not reconnect within 60 seconds: auto-promote the longest-tenured non-host participant (earliest `joined_at`). New `host_token` generated and sent via PubSub only to the promoted participant. `host:transferred` broadcast to all.
6. If only the host is in the bracket, no transfer occurs; cleanup timer will eventually terminate it.

### 2.6 Screen Accessibility

- **Focus management:** When `phase` changes (e.g., `:lobby` → `:voting`), a JS hook (`phx-hook="FocusManager"`) moves focus to the new screen's primary heading (`<h1>` with `tabindex="-1"`). Required because LiveView patches the DOM without moving focus.
- **Vote buttons:** `<button>` elements with `aria-label="Vote for [Item Name]"` and `aria-pressed="true"` when selected. Keyboard-activatable via Enter/Space.
- **Timer bar:** `role="timer"` attribute. `aria-live="assertive"` on the warning text that appears at ≤10s.
- **Vote progress:** `aria-live="polite"` on the "X of Y voted" display.
- **Bracket panel:** Focus trap, `aria-modal="true"`, `role="dialog"`, Escape-to-close.
- **Contrast:** Minimum 4.5:1 ratio (WCAG 2.1 AA) on all interactive elements. Voted state uses color change AND checkmark icon (not color alone).

---

## 3. Data Model

All state lives in GenServer processes (one per bracket). No database.

### 3.1 Core Structs (Elixir)

```elixir
defmodule Bracket.Game do
  defstruct [
    :id,                    # string, 8 chars base62
    :name,                  # string, max 100 chars
    :host_token,            # string, Base64 of 32 random bytes — NEVER broadcast
    :host_lv_pid,           # pid | nil, current LiveView pid of host
    :host_monitor_ref,      # reference | nil, from Process.monitor(host_lv_pid)
    :status,                # :lobby | :active | :finished
    :items,                 # [string | nil], padded to power-of-2 with nil (byes)
    :rounds,                # [%Round{}]
    :current_round,         # integer, 0-indexed
    :current_matchup,       # integer, index within current round
    :participants,          # %{participant_id => %Participant{}}
    :timer_seconds,         # integer | nil (5–300)
    :timer_ref,             # reference | nil (from Process.send_after — always cancel before starting new)
    :created_at,            # DateTime
    :last_activity_at       # DateTime
  ]
end

defmodule Bracket.Game.Participant do
  defstruct [
    :id,                    # string, generated server-side, stored in signed session
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
    :votes,    # %{participant_id => :a | :b} — NEVER broadcast to clients
    :winner,   # string | nil (set when matchup closes)
    :status    # :pending | :active | :closed
  ]
end

defmodule Bracket.Game.Round do
  defstruct [:matchups]  # [%Matchup{}]
end
```

### 3.2 Public State (Sanitized for Broadcast)

`Bracket.Game.public_view/1` strips all fields that must never reach clients:
- `host_token` → `nil`
- `host_monitor_ref` → `nil`
- `timer_ref` → `nil`
- Each matchup's `votes` map → replaced with `%{count_a: n, count_b: n, total_eligible: n}`

This function is called by BracketServer before every PubSub broadcast. Individual votes and credentials never leave the server process.

### 3.3 Bracket Seeding Logic

1. Accept N items (4 ≤ N ≤ 32)
2. Deduplicate, sanitize, enforce length limits
3. Calculate next power of 2: `size = :math.pow(2, ceil(:math.log2(N))) |> trunc()`
4. Shuffle items randomly with `Enum.shuffle/1`
5. Fill remaining slots with `nil` (byes): `items ++ List.duplicate(nil, size - N)`
6. Build round 0 matchups: `Enum.chunk_every(padded_items, 2)`
7. Any matchup with a bye auto-advances the non-bye item immediately (status: `:closed`, winner set)
8. `current_matchup` starts at the first non-closed matchup in round 0

### 3.4 Round Progression

- All matchups in a round are presented sequentially (one at a time, everyone votes on the same matchup)
- When a matchup closes, winner determined by majority of eligible votes
- Tie-breaking: host vote wins; if host didn't vote, random
- When all matchups in a round close, next round is built from winners
- Final round winner = champion

### 3.5 Bracket Cleanup (GenServer Lifecycle)

- Child spec uses `restart: :transient` — the GenServer is NOT restarted on normal exit. Brackets have a finite lifecycle; `:permanent` restart would spawn zombie brackets.
- On init: `{:ok, state, {:continue, :schedule_cleanup}}` → `handle_continue/2` calls `Process.send_after(self(), :check_activity, @cleanup_interval)`
- `handle_info(:check_activity, state)`: if inactive > 4 hours and finished, or inactive > 8 hours regardless, return `{:stop, :normal, state}` (does NOT call `DynamicSupervisor.terminate_child` on itself)
- `terminate/2` callback fires on normal stop, providing a hook for future serialization

---

## 4. Architecture

### 4.1 System Architecture

```
Browser (Phoenix LiveView)
    │  persistent WebSocket (HTTP upgrade)
    │
BracketWeb.Endpoint
    │
BracketWeb.BracketLive  ─── subscribe ──► Phoenix.PubSub / Bracket.PubSub ("bracket:{id}")
    │                                              ▲
    │  GenServer call (state reads, host actions)  │ broadcast public_view/1 only
    │  GenServer cast (votes — fire and forget)    │
    ▼                                              │
Bracket.BracketServer   ──────────────────────────┘
    │  state: %Bracket.Game{} (full, with host_token and votes map)
    │
    ├── registered in Bracket.Registry under bracket_id
    └── supervised by Bracket.DynamicSupervisor (restart: :transient, max_children: 1000)
```

**Key Elixir concepts exercised:**
- `GenServer` — `BracketServer` holds all bracket state; synchronous calls for host actions and state reads, async casts for votes
- `Registry` — lookup a bracket's GenServer pid by bracket ID (`{:via, Registry, {Bracket.Registry, id}}`)
- `DynamicSupervisor` — spawn/supervise bracket processes. `restart: :transient` means normal exits don't restart. `max_children: 1000` caps load.
- `Phoenix.PubSub` (named `Bracket.PubSub`) — broadcast sanitized public state to all LiveView sessions
- `LiveView` — handle real-time UI without custom WebSocket code; `handle_info/2` handles PubSub messages

### 4.2 OTP Supervision Tree

```
Bracket.Application (Supervisor, :one_for_one)
├── Bracket.Registry          (Registry, keys: :unique)
├── Bracket.DynamicSupervisor (DynamicSupervisor, max_children: 1000)
├── Bracket.PubSub            (Phoenix.PubSub, adapter: Phoenix.PubSub.PG2)
└── BracketWeb.Endpoint       (Phoenix endpoint)
```

### 4.3 LiveView Architecture

```
BracketLive (one per browser tab)
    │
    ├── mount/3
    │   ├── if connected?(socket): subscribe to "bracket:{id}"
    │   ├── call BracketServer.get_state/1 → public_view → assigns
    │   ├── read participant_id from session (server-generated, tamper-proof)
    │   └── determine phase from game state + participant status
    │
    ├── handle_event("join", %{"name" => name}, socket)
    │   └── call BracketServer.join/3 → returns {:ok, participant_id}
    │       → put participant_id in session → PubSub broadcasts public state
    │
    ├── handle_event("vote", %{"choice" => c, "matchup_id" => mid}, socket)
    │   └── cast BracketServer.vote/4 (fire-and-forget; state update comes via PubSub)
    │
    ├── handle_event("start", _, socket)          [host only, verified server-side]
    ├── handle_event("close_matchup", _, socket)  [host only]
    ├── handle_event("kick", %{"id" => id}, socket) [host only]
    ├── handle_event("restart", _, socket)        [host only]
    │
    └── handle_info({:bracket_event, event, public_game}, socket)
        └── update assigns → LiveView diffs/patches DOM automatically
```

### 4.4 Separation of Concerns

- `Bracket.Game` — **pure functions only**. Takes `%Game{}`, returns `{:ok, %Game{}}` or `{:error, reason}`. Zero PubSub, Process, or side-effect calls.
- `Bracket.BracketServer` — **thin orchestration layer**. Calls `Bracket.Game` functions, then handles side effects: PubSub broadcasts, `Process.send_after`, `Process.monitor`, timer cancellation.
- `BracketWeb.BracketLive` — **UI layer only**. Calls `BracketServer` for all state mutations. Renders from assigns.

### 4.5 Vote Authorization and Participant Identity

- `participant_id` is generated **server-side** in `BracketServer.join/2`. It is stored in the signed Phoenix session (tamper-proof cookie) and never in localStorage.
- On LiveView mount, `participant_id` is read from the session. A JS hook is NOT used for this — session state is the authoritative source.
- On every vote cast, `BracketServer` verifies: participant exists in `game.participants`, is eligible for the current matchup, and the matchup is `:active`.
- Since votes use `GenServer.cast/2`, a vote that arrives after a matchup closes is simply ignored in `handle_cast` (status check).

### 4.6 URL / Routing

```elixir
scope "/", BracketWeb do
  pipe_through :browser

  live "/", HomeLive
  live "/bracket/:id", BracketLive
  live "/bracket/:id/host", BracketLive   # host recovery: reads token from query params, validates, stores in session
end
```

### 4.7 Host Authentication

- On creation, `BracketServer` generates a `host_token` (`Base.encode64(:crypto.strong_rand_bytes(32))`). Returned to `HomeLive` which stores it in the signed Phoenix session via `put_session/3`.
- On `BracketLive` mount, `host_token` is read from the session. The LiveView passes it to `BracketServer` on join; the server marks the participant as host.
- Host recovery: `/bracket/:id/host?token=xxx` reads the token from query params, validates it against `BracketServer.validate_host_token/2`, and stores it in the session. Redirects to `/bracket/:id`.
- All host-action `handle_call` clauses verify `host_token` from the socket's session assignment, not from event payloads.

### 4.8 Timer Lifecycle (Critical)

Every matchup timer must follow this protocol to prevent stale timer messages from closing the wrong matchup:

1. When a matchup becomes active and `timer_seconds` is set: `ref = Process.send_after(self(), {:timer_expired, matchup_id}, timer_seconds * 1000)`, store `ref` in `game.timer_ref`
2. When a matchup closes (by any means: all voted, host close, timer): `if game.timer_ref, do: Process.cancel_timer(game.timer_ref)`, set `game.timer_ref = nil`
3. `handle_info({:timer_expired, matchup_id}, state)`: check `state.current_matchup == matchup_id && matchup.status == :active` before processing. Stale messages are no-ops.

### 4.9 Input Sanitization

All user strings are sanitized in `Bracket.Sanitizer`:
- Escape HTML using `Phoenix.HTML.html_escape/1`
- Trim whitespace
- Enforce length limits
- Dedup items

LiveView templates use `<%= %>` by default (HTML-escaping). No `raw/1` on user-supplied strings.

### 4.10 No REST API

All create/join/vote actions happen through LiveView events. No separate HTTP/JSON layer needed. Idiomatic Phoenix LiveView.

---

## 5. LiveView Screens / States

`BracketLive` is a single LiveView rendering different UI based on `socket.assigns.phase`:

| Phase | Trigger | View |
|-------|---------|------|
| `:connecting` | `not connected?(socket)` | Skeleton screen with spinner (static render gap) |
| `:join_form` | Connected, bracket in `:lobby` or `:active`, no participant_id in session | Name entry form |
| `:lobby` | After join, bracket status `:lobby` | Participant list + share link; timer settings (host only); Start button (host only) |
| `:voting` | After `bracket:started` or rejoin mid-vote (eligible) | Two items + vote buttons + "X of Y voted"; host gets "Close Matchup" + timer bar if active |
| `:waiting` | Late joiner during active matchup (ineligible) | Current matchup items (read-only), vote progress, participant list, "View Bracket" button; message: "You joined mid-round. You can vote starting next matchup." |
| `:champion` | After final matchup closes | Winner celebration + full bracket tree; host sees "Restart" button |
| `:finished` | Mount on finished bracket | Read-only bracket results |
| `:not_found` | BracketServer not found | "Bracket not found" + link to create new |
| `:kicked` | Receive `{:kicked, participant_id}` PubSub msg | "You were removed from this bracket" + link to home |
| `:reconnecting` | JS hook detects > 5s disconnect | Overlay banner; buttons disabled |
| `:disconnected` | JS hook detects > 30s disconnect | Full-screen "Connection lost" + "Try Again" |

---

## 6. Components

### BracketTree
Renders the full bracket as a CSS Grid layout:
- Each round is a column; matchups are rows within columns
- Connector lines via CSS pseudo-elements
- Current matchup highlighted; winners bold, losers dimmed; future slots empty
- Horizontal scroll with `touch-action: pan-x` for large brackets (16–32 items)

### VoteButtons
Two large `<button>` elements side-by-side:
- `aria-label="Vote for [Item Name]"`, `aria-pressed="true"` when selected
- Both buttons remain **active and tappable** while the matchup is open (vote changes supported)
- Selected button shows checkmark icon + highlighted border (color AND icon)
- Both buttons disabled only after matchup closes (status `:closed`)

### ParticipantList
Live count + names. Connected/disconnected status indicator. Host sees kick buttons. Capped at 50 entries.

### TimerBar
Fixed bar at top during timed rounds:
- `role="timer"`, `aria-live="assertive"` on warning text at ≤10s
- CSS animation for pulse at ≤10s; "Last chance!" text at ≤5s
- Hidden when `timer_seconds == nil`

### SettingsPanel (Host only)
Gear icon in host header. Available in lobby and between matchups. Contains timer toggle and seconds input (5–300). Shows timer settings to all participants in lobby.

---

## 7. Tech Stack

| Layer | Technology | Rationale |
|-------|-----------|-----------|
| Framework | Phoenix 1.8 | Batteries-included Elixir web framework |
| Real-time UI | Phoenix LiveView 1.1 | Replaces Socket.io entirely; real-time over WebSocket with server-rendered HTML diffs |
| State | GenServer per bracket (`restart: :transient`) | Isolated, finite lifecycle; crash-recoverable; OTP supervision |
| Storage | In-memory GenServer state | Brackets are ephemeral; no DB needed for v1 |
| IDs | `:crypto.strong_rand_bytes` + base62 | URL-safe, hard-to-guess bracket IDs |
| CSS | Tailwind (Phoenix default) | Mobile-first utility classes; DaisyUI deferred unless specific components prove useful |
| Deployment | Render | Same platform as Node.js version; `mix release` for production |

---

## 8. Architecture Decisions & Tradeoffs

### Decision 1: GenServer per bracket with `restart: :transient`
**Choice:** One GenServer per bracket, child spec `restart: :transient`
**Rationale:** Crash isolation is free. `:transient` means the process is NOT restarted on normal exit (bracket finished, cleaned up) — avoiding zombie bracket respawns. Only abnormal exits (bugs) trigger a restart, giving crash recovery without infinite loops.

### Decision 2: LiveView only, no REST API
**Choice:** LiveView events only (no `POST /api/brackets`)
**Rationale:** Everything flows through the same WebSocket. No separate HTTP/JSON layer. Simpler, more idiomatic Phoenix.

### Decision 3: `GenServer.cast` for votes, `call` for everything else
**Choice:** Votes use `cast` (async); host actions and state reads use `call` (sync)
**Rationale:** With 50 participants voting simultaneously, synchronous `call` with a 5-second timeout would cause vote timeouts under load. Votes are idempotent (last write wins per participant) so fire-and-forget with PubSub confirmation is correct. State updates arrive via PubSub broadcast, not the cast return value.

### Decision 4: PubSub broadcasts only aggregate vote counts, never individual votes
**Choice:** `public_view/1` strips `matchup.votes` map, replacing with `{count_a, count_b, total_eligible}`
**Rationale:** In a friend group, knowing who voted for what creates social pressure and changes voting behavior. Individual votes are retained server-side only for tie-breaking. This matches Node.js Decision 8.

### Decision 5: Broadcast full public state on structural changes; vote counts on vote events
**Choice:** Full `public_view(game)` broadcast on join/leave/start/close. Only `{count_a, count_b, total_eligible}` broadcast on each vote.
**Rationale:** High-frequency vote events (50 participants simultaneously) would make broadcasting the full state wasteful. Sending only the counts delta reduces serialization cost from O(state_size × participants) to O(1 × participants) for the most common event.

### Decision 6: `participant_id` in signed session, not localStorage
**Choice:** Server generates `participant_id`, stores in signed Phoenix session
**Rationale:** localStorage is accessible to client-side code and can be spoofed. A participant who knows another's ID could impersonate them and cast votes on their behalf. Signed session cookies are tamper-proof and survive browser refreshes/WiFi blips (same as localStorage) without the security risk.

### Decision 7: No database for v1
**Choice:** In-memory GenServer state only
**Rationale:** Brackets are ephemeral. `GenServer.terminate/2` provides a natural hook for future serialization in v2.

### Decision 8: Sequential matchups
**Choice:** Sequential (everyone votes on the same matchup)
**Rationale:** Creates shared experience. Simpler state machine. Matches Node.js v1 behavior.

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
- `PORT` — HTTP port (Render injects automatically)
- `SECRET_KEY_BASE` — 64-byte hex string (`mix phx.gen.secret`)
- `PHX_HOST` — production hostname for LiveView WebSocket URL verification

**Health check:** Add `GET /health` route that returns bracket count from `DynamicSupervisor.count_children/1`, uptime, and memory usage.

**Scaling note:** `Bracket.PubSub` uses the PG2 adapter and works across a cluster. For multi-node horizontal scaling, replace with Redis adapter. GenServer state would need distributed ETS or a database (v2 concern).
