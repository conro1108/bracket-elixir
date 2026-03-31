# TEST_PLAN.md — Bracket Elixir Test Strategy & Regression Plan

## Test Strategy Summary

This is a real-time bracket tournament app built on Phoenix LiveView where each bracket is an isolated GenServer process. The testing strategy exploits the natural layering of the architecture:

1. `Bracket.Game` is a pure-function module with zero side effects — it receives a struct, returns a struct, and is trivially unit-testable.
2. `Bracket.BracketServer` is a GenServer that wraps `Bracket.Game` and adds process concerns (PubSub broadcasts, timers, host monitoring) — it gets integration tests that start real GenServer processes.
3. `BracketWeb.BracketLive` and `BracketWeb.HomeLive` are LiveViews that call the GenServer and react to PubSub — they get feature tests using `Phoenix.LiveViewTest`.

**No mocks are used at any layer.** There is no database, no external service, and no HTTP API — every test runs against real processes in the test environment.

---

## 1. Unit Tests

### Target: `Bracket.Game` → `test/bracket/game_test.exs`

All tests operate on `%Bracket.Game{}` structs. Pure functions, no side effects.

#### 1.1 Bracket Creation / Seeding (`Bracket.Game.new/3`)

- **Power-of-2 padding:**
  - 4 items → 4 slots (no byes)
  - 5 items → 8 slots (3 byes)
  - 7 items → 8 slots (1 bye)
  - 9 items → 16 slots (7 byes)
  - 17 items → 32 slots
  - 32 items → 32 slots (no byes)
  - Assert `length(game.items) == expected_power_of_2`
- **Bye placement:** Matchups with `item_a == nil` or `item_b == nil` auto-resolve with status `:closed` and winner = non-nil item
- **Round 0 construction:** One round with `div(power_of_2, 2)` matchups pairing consecutive items
- **Shuffle randomness:** Two calls with same input produce different orderings (with very high probability)
- **ID:** 8-character base62 string
- **host_token:** Non-empty Base64 string
- **Status:** `:lobby` after creation
- **Timestamps:** `created_at` and `last_activity_at` are set
- **Validation — too few:** < 4 items → `{:error, :too_few_items}`
- **Validation — too many:** > 32 items → `{:error, :too_many_items}`
- **Validation — empty name:** `{:error, :invalid_name}`
- **Validation — name length:** > 100 chars → rejected or truncated
- **Validation — item length:** > 100 chars per item → rejected or truncated
- **Deduplication:** `["A", "B", "A", "C", "D"]` → 4 unique items

#### 1.2 Participant Management

- **`add_participant/3`:** Adds participant with `connected: true`, `eligible_from_matchup: nil` (lobby join)
- **Duplicate display name:** "Alex" exists → new participant gets "Alex 2" → next gets "Alex 3"
- **Display name max length:** > 30 chars rejected or truncated
- **Late join eligibility:** `game.status == :active` → `eligible_from_matchup = current_matchup + 1`
- **Lobby join:** `eligible_from_matchup: nil` (eligible for all matchups)
- **Remove participant (kick):** Removes from `participants` map; votes in active matchup are removed
- **Host flag:** Creating participant has `is_host: true`

#### 1.3 Bracket Start (`start_bracket/2`)

- **Lobby → active:** `status` becomes `:active`, `current_round: 0`, `current_matchup` = first non-bye matchup
- **First matchup activated:** Matchup at `current_matchup` has `status: :active`
- **Reject if not lobby:** `{:error, :not_in_lobby}`
- **Wrong host token:** `{:error, :unauthorized}`

#### 1.4 Voting (`record_vote/4`)

- **Cast a vote:** Adds `participant_id => :a` to `matchup.votes`. Returns `{:ok, game}`.
- **Change a vote:** Voting `:b` after `:a` overwrites. One entry per participant.
- **Ineligible voter:** `{:error, :not_eligible}` if `eligible_from_matchup > current_matchup`
- **Wrong matchup:** `{:error, :matchup_not_active}` for non-current matchup
- **Closed matchup:** `{:error, :matchup_not_active}`
- **Non-participant:** `{:error, :not_a_participant}`
- **Finished bracket:** Error returned

#### 1.5 Matchup Closing (`close_matchup/1`)

- **Majority winner:** 3 votes A, 1 vote B → `matchup.winner = item_a`, `status: :closed`
- **Tie-break with host vote:** 2A (including host), 2B → winner is item_a
- **Tie-break without host vote:** 1A, 1B, host abstained → winner is one of the two (random)
- **`was_tie_breaker` flag:** Set when tie-break occurs
- **No votes cast:** Random winner, one of the two items
- **Only eligible votes counted** (defense-in-depth even if `record_vote` guards first)

#### 1.6 Round Progression (`advance/1`)

- **Next matchup in round:** `current_matchup` advances to next non-bye matchup; that matchup becomes `:active`
- **Next round generation:** After all matchups in round N close, round N+1 is appended pairing winners
- **Champion detection:** Final round's single matchup closes → `status: :finished`
- **`current_round` and `current_matchup`** update correctly across round boundaries
- **Skip auto-closed bye matchups** when advancing

#### 1.7 Bracket Restart (`restart/1`)

- **Items re-shuffled:** New random ordering
- **Status reset:** `status: :lobby`
- **Participants preserved:** All participants remain with `eligible_from_matchup: nil`
- **Votes cleared:** All matchup votes empty, rounds rebuilt

#### 1.8 Host Transfer (`transfer_host/2`)

- **New host token:** New `host_token` generated, old one invalidated
- **Participant flags:** Old host `is_host: false`, new host `is_host: true`
- **Longest-tenured selection:** Participant with earliest `joined_at` (excluding current host)

#### 1.9 Timer Validation

- `set_timer(game, 60)` → `game.timer_seconds = 60`
- Values outside 5–300 rejected
- Timer state independent of `timer_ref` (which lives only in BracketServer)

### Target: `Bracket.Sanitizer` → `test/bracket/sanitizer_test.exs`

- HTML stripping: `<script>alert('x')</script>` → escaped text
- Whitespace trimming: `"  hello  "` → `"hello"`
- Length enforcement: string longer than limit → truncated to limit
- Unicode: multi-byte chars preserved and counted correctly

### Target: `Bracket.IdGenerator` → `test/bracket/id_generator_test.exs`

- Bracket IDs: 8 characters, base62 only (a-z, A-Z, 0-9)
- Uniqueness: 1000 generated IDs have no duplicates
- Participant IDs: non-empty strings

---

## 2. Integration Tests

### Target: `Bracket.BracketServer` → `test/bracket/bracket_server_test.exs`

Start real GenServer processes via DynamicSupervisor. Use real `Bracket.PubSub`. No mocks.

#### 2.1 Process Lifecycle

- **Create and register:** `BracketServer.create(attrs)` starts a GenServer in `Bracket.Registry`; lookup by ID returns the PID
- **Get state:** `BracketServer.get_state(id)` returns a sanitized (public) `%Bracket.Game{}` (no `host_token`)
- **Process isolation:** Two brackets have independent state
- **Restart strategy:** Since `restart: :transient`, if the process exits normally it is NOT restarted. Assert `Registry.lookup` returns `[]` after clean stop.
- **Registry cleanup:** After BracketServer stops, `BracketServer.get_state(id)` returns `{:error, :not_found}`

#### 2.2 Join Flow

- **Join in lobby:** Returns `{:ok, participant_id}` with server-generated ID
- **Join broadcasts via PubSub:** Subscribe to `"bracket:#{id}"`, join, assert `{:bracket_event, :participant_joined, game}` received
- **Rejoin with participant_id:** Calling join with existing ID updates `connected: true` and `lv_pid`, no duplicate
- **Join finished bracket:** Returns `{:error, :bracket_finished}` or renders read-only

#### 2.3 Voting Flow

- **Vote and broadcast:** Cast via `BracketServer.vote/4` (async). Assert PubSub broadcast with updated vote counts (NOT individual votes) is received.
- **All-voted auto-close:** All eligible participants vote → matchup auto-closes → PubSub broadcast with winner → next matchup becomes active
- **Vote authorization:** Invalid `participant_id` → no state change (GenServer ignores the cast silently or logs error)

#### 2.4 Host Actions

- **Start:** `BracketServer.start_bracket(id, host_token)` → `:active`, PubSub broadcasts `:bracket_started`
- **Close matchup early:** `BracketServer.close_matchup(id, host_token)` → closes regardless of vote count
- **Kick:** `BracketServer.kick(id, host_token, participant_id)` → participant removed, PubSub broadcasts `:kicked` message
- **Restart:** `BracketServer.restart(id, host_token)` → `:lobby`, PubSub broadcasts `:bracket_restarted`
- **Unauthorized:** Wrong token → `{:error, :unauthorized}`, state unchanged

#### 2.5 Timer Integration

- **Timer triggers close:** Start bracket with `timer_seconds: 1` (or use test config override). Assert matchup auto-closes after ~1s. PubSub broadcasts close event.
- **Timer canceled on manual close:** Close matchup before timer fires. Late `:timer_expired` message is a no-op (matchup already closed, ID check fails).
- **Timer canceled on all-voted:** All vote before timer. Late timer message is no-op.

#### 2.6 Host Disconnect and Transfer

- Register host's LiveView PID with BracketServer. Kill the PID. Assert transfer occurs after the configured timeout (use short timeouts in test config, e.g., 100ms).
- Transfer broadcasts via PubSub: new host has `is_host: true`, new `host_token` generated.
- **No transfer if reconnects:** Host disconnects, re-registers PID within timeout. No transfer.

#### 2.7 Cleanup / Inactivity

- **Inactive bracket terminates:** With short test config intervals, assert GenServer terminates after inactivity threshold.
- **Active bracket does not terminate:** Recent `last_activity_at` prevents early cleanup.

#### 2.8 Full Game Walkthrough (Smoke Test)

```
Create bracket (4 items)
→ 2 participants join
→ host starts
→ both vote matchup 0 (same choice) → auto-closes → advances
→ both vote matchup 1 → auto-closes → round 1 generated
→ both vote final matchup → champion
Assert: game.status == :finished, champion is correct item
```

---

## 3. LiveView Feature Tests

### Test files:
- `test/bracket_web/live/home_live_test.exs`
- `test/bracket_web/live/bracket_live_test.exs`

Use `Phoenix.LiveViewTest`. Start real BracketServer processes. No mocks.

#### 3.1 HomeLive — Bracket Creation

- **Happy path:** Fill name + 4+ items + host name. Submit. Assert redirect to `/bracket/:id`. Assert BracketServer exists.
- **Too few items:** 3 items → form error, no redirect
- **Too many items:** 33 items → form error
- **Empty name:** → form error
- **Item length:** 101-char item → rejection or truncation
- **Bulk paste:** Newline-separated items parsed into individual items
- **Deduplication:** Duplicate items removed before bracket created

#### 3.2 BracketLive — Join Flow

- **Join form rendered:** Visit `/bracket/:id` for lobby bracket → name input visible
- **Join with name:** Submit name → transitions to lobby phase → participant in list
- **Duplicate name suffix:** Two connections join "Alex" → second is "Alex 2"
- **Bracket not found:** `/bracket/nonexistent` → "Bracket not found" message
- **Finished bracket — read-only:** Complete a bracket, visit URL → results shown, no vote buttons

#### 3.3 BracketLive — Lobby Phase

- **Participant list updates live:** Two connections; B joins → A's view updates with both names
- **Share link displayed:** Shareable URL visible in lobby
- **Host sees Start button, non-host does not**
- **Start bracket:** Host clicks Start → both views transition to voting phase, first matchup shown

#### 3.4 BracketLive — Voting Phase

- **Matchup displayed:** Two items + vote buttons visible
- **Cast a vote:** Click one item → selection highlighted (checkmark/border class)
- **Change a vote:** Click other item → selection switches
- **Both buttons active while matchup open:** Assert no `disabled` attribute on unselected button
- **Vote progress:** After one votes, view shows "1 of 2 voted"
- **Auto-close when all voted:** Both vote → winner interstitial → next matchup
- **Host close matchup:** Host clicks "Close Matchup" → closes even if not all voted
- **Late joiner waiting state:** New participant joins mid-matchup → sees read-only matchup + "You joined mid-round" message, NO vote buttons → after matchup closes and next starts, sees vote buttons

#### 3.5 BracketLive — Champion Phase

- **Champion displayed:** Winner's name prominent
- **Full bracket tree visible**
- **Host sees Restart button**
- **Restart returns to lobby:** Host clicks Restart → both views back to lobby

#### 3.6 BracketLive — Kicked Participant

- **Kick renders removal screen:** Host kicks participant → kicked view shows "You were removed"
- **Kicked participant removed from list**

#### 3.7 BracketLive — Bracket View Panel

- **"View Bracket" button present:** In lobby, voting, and champion phases
- **Bracket tree renders current state:** Current matchup highlighted, past results shown, future empty

#### 3.8 LiveView Reconnect

- After simulated disconnect/reconnect (new `live/2` call with same session), participant sees correct phase and previous votes restored

---

## 4. Test Data Factories

### File: `test/support/bracket_factory.ex`

Plain module functions, no external library:

```elixir
# Returns %Bracket.Game{} with 4 items, :lobby status, no participants
build_game(opts \\ [])

# Returns game with N participants already added
build_game_with_participants(n, opts \\ [])

# Returns game with status :active, round 0 built, first non-bye matchup active
build_active_game(opts \\ [])

# Returns game advanced to a specific matchup index (for progression tests)
build_game_at_matchup(matchup_index, opts \\ [])

# Returns %Bracket.Game.Participant{} with defaults
build_participant(opts \\ [])

# Returns %Bracket.Game.Matchup{} with defaults
build_matchup(opts \\ [])

# Starts real BracketServer via DynamicSupervisor. Returns {:ok, id, host_token}
create_bracket_server(opts \\ [])

# Calls BracketServer.join/2. Returns participant_id
join_participant(bracket_id, display_name)

# Creates bracket, adds N participants, starts it. Returns {id, host_token, [participant_ids]}
advance_to_voting(n_participants, opts \\ [])

# All participants vote for choice on current matchup. Advances game.
play_through_matchup(bracket_id, participant_ids, choice)

# Creates game with fixed item order (bypass shuffle) for deterministic bracket tests
build_game(items: [...], shuffle: false)
```

---

## 5. Regression Gates

### Must Pass Before Any Merge

1. `mix compile --warnings-as-errors` — zero warnings
2. `mix format --check-formatted` — no unformatted code
3. `mix test` — zero failures
4. `mix precommit` (existing alias: compile + deps.unlock --unused + format + test)

### Smoke Tests (Never Break — Block Deploy)

Tag with `@tag :smoke`. Run with `mix test --only smoke`.

- `Bracket.Game` — Create 4-item bracket, verify struct valid
- `Bracket.Game` — Record vote, verify stored
- `Bracket.Game` — Close matchup, verify winner determined
- `Bracket.Game` — Play 4-item bracket to completion, verify champion
- `BracketServer` — Create → join → vote → close full lifecycle
- `HomeLive` — Create form submits and redirects
- `BracketLive` — Join → lobby → host starts → voting phase visible

### High-Risk Regression Areas

| Area | Risk | Tests |
|------|------|-------|
| Vote counting / tie-breaking | Wrong winner corrupts bracket | All `close_matchup` unit tests, tie-break matrix |
| Round progression | Bracket gets stuck or skips matchups | All `advance` unit tests, bye-skip tests |
| Late join eligibility | Late joiner votes illegally or locked out permanently | `eligible_from_matchup` unit tests, late-join LV test |
| Host authentication | Non-host can start/close/kick | All unauthorized-action tests (unit + integration) |
| Host transfer | Bracket orphaned on host disconnect | Host disconnect integration tests |
| Bye handling | Byes not auto-advanced, bracket broken | Bye auto-advance unit tests, odd-item-count tests |
| PubSub correctness | Stale state sent to participant | All integration tests asserting PubSub messages |
| Vote anonymity | Individual votes broadcast to clients | Assert public_view() strips votes map in all broadcasts |
| Concurrent votes / auto-close | Last vote + timer race → double close | Timer integration tests, all-voted-auto-close tests |

---

## 6. Edge Cases — Explicit Test Scenarios

### 6.1 Late Join Eligibility

- Join in lobby → `eligible_from_matchup: nil` → votes on all matchups
- Join during matchup 0 → `eligible_from_matchup: 1` → can't vote on 0, can on 1+
- Join during final matchup → never votes, sees champion screen at end
- Late joiner is only participant besides host → host vote alone determines winner

### 6.2 Tie-Breaking Matrix

| Scenario | Expected |
|---------|---------|
| Tie, host voted A | A wins |
| Tie, host voted B | B wins |
| Tie, host abstained | Random (A or B) |
| 0 total votes | Random |
| Only host voted | Host's choice wins |
| Only non-host voted (single voter) | That vote wins |
| 2 participants, 1A 1B, neither is host | Tie, random winner |

### 6.3 Bye Handling

- 5 items → 8 slots, 3 byes: 3 matchups in round 0 auto-closed, 1 real matchup
- 4 items → 0 byes: all round 0 matchups require voting
- 8 items → 0 byes: all matchups require voting
- Bye winner advances to round 1 as a real item in a votable matchup
- Assert champion can be determined even when byes cluster on one side

### 6.4 Host Disconnect and Transfer

- Reconnect within 30s → no transfer, host retains control
- No reconnect within 60s → longest-tenured participant promoted
- Only one other participant → that participant promoted
- No other participants → orphaned bracket, cleanup timer eventually terminates
- New host token is valid, old token is invalid

### 6.5 Concurrent Votes

- All 50 participants vote simultaneously → matchup auto-closes exactly once (no double-close)
- Vote cast arrives after matchup closed → ignored (cast is no-op on closed matchup)
- Two rapid votes from same participant → only last vote recorded

### 6.6 Bracket Sizes

| Items | Slots | Round 0 matchups | Real / Bye | Total rounds |
|-------|-------|-----------------|------------|-------------|
| 4 | 4 | 2 | 2/0 | 2 |
| 5 | 8 | 4 | 1/3 | 3 |
| 8 | 8 | 4 | 4/0 | 3 |
| 9 | 16 | 8 | 1/7 | 4 |
| 32 | 32 | 16 | 16/0 | 5 |

Assert 32-item bracket plays to champion (31 total matchups).

### 6.7 Degenerate States

- 0 participants when host clicks start: either prevent (if participants required) or allow host to vote alone
- All participants disconnect mid-voting: bracket stays active until timer or host close. No crash.
- Stale timer message on different matchup: ignored (matchup_id mismatch check)

---

## 7. Test Configuration

### `config/test.exs` additions needed:

```elixir
config :bracket, :cleanup_interval, 100              # ms (production: 5 min)
config :bracket, :cleanup_inactive_threshold, 200    # ms (production: 4 hours)
config :bracket, :host_disconnect_warning_ms, 50     # ms (production: 30s)
config :bracket, :host_disconnect_transfer_ms, 100   # ms (production: 60s)
```

Use `Application.get_env/3` with defaults in BracketServer for all timing constants.

### Test Tags

- `@tag :smoke` — minimum viability, fast, run in CI on every commit
- `@tag :slow` — timer/cleanup tests involving real waits (excluded by default)
- `async: true` — on all unit test modules (pure data, no shared state)
- `async: false` — on integration and LiveView tests (shared PubSub, Registry)

### Running Tests

```bash
# Full suite
mix test

# Smoke only (fast)
mix test --only smoke

# Exclude slow timer tests
mix test --exclude slow

# With coverage
mix test --cover
```

**Coverage targets:** 90%+ on `Bracket.Game`, 80%+ on `Bracket.BracketServer`, 70%+ on LiveView modules. The specific test cases above matter more than the percentage.

---

## 8. Test File Structure

```
test/
├── test_helper.exs
├── support/
│   ├── conn_case.ex                          # Existing
│   ├── live_view_case.ex                     # New: LiveView test case + session helpers
│   └── bracket_factory.ex                    # New: test data factories
├── bracket/
│   ├── game_test.exs                         # Unit: seeding, voting, progression
│   ├── sanitizer_test.exs                    # Unit: input sanitization
│   ├── id_generator_test.exs                 # Unit: ID generation
│   ├── bracket_server_test.exs               # Integration: GenServer lifecycle
│   └── bracket_server_timer_test.exs         # Integration: timer-specific (tagged :slow)
└── bracket_web/
    └── live/
        ├── home_live_test.exs                # Feature: bracket creation form
        └── bracket_live_test.exs             # Feature: all phases and transitions
```

---

## 9. Known Gaps (Future Coverage)

| Gap | Mitigation |
|-----|-----------|
| JS hook for reconnection UX | LiveView tests can't execute JS; test state restoration via session. Browser E2E (Wallaby) deferred to v2. |
| Visual/CSS states (timer bar, bracket tree layout) | Assert CSS classes and data attributes. Visual regression deferred. |
| Load/stress testing (50 participants, 1000 brackets) | Separate load test script (k6 or custom Elixir). Deferred to pre-launch. |
| SIGTERM / graceful shutdown | Manual testing or dedicated integration environment. |
| Randomness in shuffle/tie-break | Use `shuffle: false` factory option. For tie-break randomness, assert winner is one of the two valid items. |
