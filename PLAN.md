# Bracket — Elixir/Phoenix LiveView Plan

Reference implementation: `../bracket/` (Node.js/Socket.io version)

## Why Elixir for this app

Bracket is a near-perfect Elixir learning project:
- Each active bracket maps naturally to a **GenServer process** — stateful, isolated, crash-recoverable
- LiveView replaces Socket.io entirely — real-time UI updates over persistent WebSocket with no custom JS
- OTP supervision trees handle cleanup/restart automatically
- The functional, immutable data model makes bracket game logic easy to test in isolation

## Stack

| Layer | Technology |
|-------|-----------|
| Framework | Phoenix 1.7+ |
| Real-time UI | Phoenix LiveView |
| State | GenServer per bracket (via Registry + DynamicSupervisor) |
| Storage | In-memory (ETS or GenServer state), same as Node.js v1 |
| IDs | `:crypto.strong_rand_bytes` encoded as base62 |
| CSS | Tailwind (Phoenix default) |
| Deployment | Render (same as Node.js version) |

## Project Structure (rough)

```
bracket_elixir/
├── lib/
│   ├── bracket/                    # Core domain (no Phoenix dependency)
│   │   ├── game.ex                 # Pure bracket logic (seeding, voting, progression)
│   │   ├── bracket_server.ex       # GenServer holding bracket state
│   │   └── bracket_registry.ex     # Registry + DynamicSupervisor management
│   └── bracket_web/
│       ├── live/
│       │   ├── home_live.ex        # Create bracket form
│       │   ├── bracket_live.ex     # Main bracket page (join → lobby → voting → champion)
│       │   └── components/
│       │       ├── bracket_tree.ex  # Bracket visualization component
│       │       └── vote_buttons.ex  # The two vote targets
│       └── router.ex
├── test/
│   └── bracket/
│       └── game_test.ex            # Pure unit tests for game logic
└── PLAN.md
```

## Key Elixir Concepts to Learn Here

1. **GenServer** — `BracketServer` holds bracket state, handles calls/casts for game actions
2. **Registry** — look up a bracket's GenServer pid by bracket ID
3. **DynamicSupervisor** — spawn/supervise bracket processes, auto-restart on crash
4. **PubSub** — broadcast bracket events to all LiveView sessions subscribed to a bracket
5. **LiveView** — handle real-time UI without writing custom WebSocket code

## Core Data Structures (Elixir)

```elixir
# lib/bracket/game.ex
defmodule Bracket.Game do
  defstruct [
    :id,
    :name,
    :host_token,
    :host_socket_id,  # current LV pid of host
    :status,          # :lobby | :active | :finished
    :items,
    :rounds,
    :current_round,
    :current_matchup,
    :participants,    # %{participant_id => participant}
    :timer_seconds,
    :created_at,
    :last_activity_at
  ]

  defmodule Participant do
    defstruct [:id, :display_name, :connected, :joined_at, :eligible_from_matchup, :is_host]
  end

  defmodule Matchup do
    defstruct [:id, :item_a, :item_b, :votes, :winner, :status]
    # votes: %{participant_id => :a | :b}
  end

  defmodule Round do
    defstruct [:matchups]
  end
end
```

## LiveView Architecture

```
BracketLive (one per browser tab)
    │
    ├── on mount → subscribe to Phoenix.PubSub topic "bracket:{id}"
    ├── handle_event("join", ...) → call BracketServer, PubSub broadcasts state
    ├── handle_event("vote", ...) → call BracketServer, PubSub broadcasts update
    └── handle_info({:bracket_event, event}) → update assigns, re-render
```

No custom JS needed for real-time updates — LiveView diffs and patches the DOM automatically.

## Routing

```elixir
# router.ex
scope "/", BracketWeb do
  pipe_through :browser

  live "/", HomeLive
  live "/bracket/:id", BracketLive
end
```

## BracketServer GenServer (sketch)

```elixir
defmodule Bracket.BracketServer do
  use GenServer

  # Client API
  def create(bracket) do
    DynamicSupervisor.start_child(Bracket.Supervisor, {__MODULE__, bracket})
  end

  def join(id, participant), do: call(id, {:join, participant})
  def vote(id, participant_id, matchup_id, choice), do: call(id, {:vote, participant_id, matchup_id, choice})
  def start_bracket(id, host_token), do: call(id, {:start, host_token})
  def close_matchup(id, host_token), do: call(id, {:close_matchup, host_token})

  # Server callbacks
  def handle_call({:vote, participant_id, matchup_id, choice}, _from, bracket) do
    with :ok <- authorize_vote(bracket, participant_id, matchup_id),
         {:ok, new_bracket} <- Bracket.Game.record_vote(bracket, participant_id, matchup_id, choice) do
      broadcast(bracket.id, {:vote_update, new_bracket})
      {:reply, :ok, new_bracket}
    else
      {:error, reason} -> {:reply, {:error, reason}, bracket}
    end
  end
end
```

## Differences from Node.js version

| Concern | Node.js | Elixir |
|---------|---------|--------|
| Real-time | Socket.io events | LiveView + PubSub |
| State | In-memory Map | GenServer per bracket |
| Crash isolation | None (one process) | Each bracket isolated |
| Cleanup | setInterval | GenServer timeout / Process.send_after |
| Auth | hostToken in WS auth | hostToken in LiveView session |
| Testing | Minimal | Game logic unit-testable in isolation |

## Build Order

1. `mix phx.new bracket_elixir --live` — scaffold Phoenix app
2. `Bracket.Game` module — pure game logic, fully tested (no Phoenix)
3. `BracketServer` GenServer + Registry + DynamicSupervisor
4. `HomeLive` — create bracket form
5. `BracketLive` — join/lobby/voting/champion (single LiveView, different states)
6. `BracketTree` component — bracket visualization
7. Deploy to Render

## Render Deployment Notes

- `mix release` for production build
- `PORT` env var (Phoenix reads it automatically)
- No database needed for v1 (same as Node.js)
- Health check: Phoenix includes `/` by default; add `GET /health` if needed
