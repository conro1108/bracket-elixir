defmodule BracketFactory do
  @moduledoc "Test data factories for bracket domain objects."

  alias Bracket.{Game, BracketServer}

  @default_items ["Alpha", "Beta", "Gamma", "Delta"]

  def build_game(opts \\ []) do
    items = Keyword.get(opts, :items, @default_items)
    name = Keyword.get(opts, :name, "Test Bracket")
    host_name = Keyword.get(opts, :host_name, "Host")
    shuffle = Keyword.get(opts, :shuffle, false)

    {:ok, game} = Game.new(name, items, host_name, shuffle: shuffle)
    game
  end

  def build_game_with_participants(n, opts \\ []) do
    game = build_game(opts)

    Enum.reduce(1..n, game, fn i, acc ->
      {:ok, {updated, _}} = Game.add_participant(acc, "Player #{i}", nil)
      updated
    end)
  end

  def build_active_game(opts \\ []) do
    game = build_game_with_participants(2, opts)
    host_token = game.host_token
    {:ok, game} = Game.start_bracket(game, host_token)
    game
  end

  def build_participant(opts \\ []) do
    %Game.Participant{
      id: Keyword.get(opts, :id, "test_participant"),
      display_name: Keyword.get(opts, :display_name, "Test User"),
      lv_pid: nil,
      connected: true,
      joined_at: DateTime.utc_now(),
      eligible_from_matchup: Keyword.get(opts, :eligible_from_matchup, nil),
      is_host: Keyword.get(opts, :is_host, false)
    }
  end

  def build_matchup(opts \\ []) do
    %Game.Matchup{
      id: Keyword.get(opts, :id, 0),
      item_a: Keyword.get(opts, :item_a, "Item A"),
      item_b: Keyword.get(opts, :item_b, "Item B"),
      votes: Keyword.get(opts, :votes, %{}),
      winner: nil,
      status: Keyword.get(opts, :status, :pending)
    }
  end

  @doc """
  Starts a real BracketServer process. Returns {:ok, id, host_token}.
  The process is started under Bracket.DynamicSupervisor.
  """
  def create_bracket_server(opts \\ []) do
    items = Keyword.get(opts, :items, @default_items)
    name = Keyword.get(opts, :name, "Test Bracket")
    host_name = Keyword.get(opts, :host_name, "Host")

    {:ok, id, host_token} = BracketServer.create(%{name: name, items: items, host_name: host_name})
    {:ok, id, host_token}
  end

  @doc "Calls BracketServer.join/2. Returns the participant_id."
  def join_participant(bracket_id, display_name) do
    {:ok, participant_id} = BracketServer.join(bracket_id, display_name, nil)
    participant_id
  end

  @doc """
  Creates a bracket, adds n participants, starts it.
  Returns {id, host_token, [participant_ids]}.
  """
  def advance_to_voting(n_participants, opts \\ []) do
    {:ok, id, host_token} = create_bracket_server(opts)
    participant_ids = Enum.map(1..n_participants, fn i -> join_participant(id, "Player #{i}") end)
    :ok = BracketServer.start_bracket(id, host_token)
    {id, host_token, participant_ids}
  end

  @doc "Has all participants vote for choice on the current matchup."
  def play_through_matchup(bracket_id, participant_ids, choice) do
    {:ok, game} = BracketServer.get_state(bracket_id)
    matchup_id = game.current_matchup

    Enum.each(participant_ids, fn pid ->
      BracketServer.vote(bracket_id, pid, matchup_id, choice)
    end)

    # Give the GenServer time to process the casts and auto-close
    Process.sleep(50)
  end
end
