defmodule Bracket.Game.Participant do
  @moduledoc "Represents a participant in a bracket game."

  @enforce_keys [:id, :display_name, :joined_at]
  defstruct [
    :id,
    :display_name,
    :lv_pid,
    :connected,
    :joined_at,
    :eligible_from_matchup,
    :is_host
  ]
end

defmodule Bracket.Game.Matchup do
  @moduledoc "Represents a single head-to-head matchup in a bracket round."

  @enforce_keys [:id]
  defstruct [
    :id,
    :item_a,
    :item_b,
    :votes,
    :winner,
    :status
  ]
end

defmodule Bracket.Game.Round do
  @moduledoc "Represents a single round in the bracket."

  defstruct [:matchups]
end

defmodule Bracket.Game do
  @moduledoc """
  Pure functions for managing bracket game state.
  No PubSub, Process calls, or side effects.
  """

  alias Bracket.Game.{Matchup, Participant, Round}
  alias Bracket.Sanitizer

  @enforce_keys [:id, :name, :host_token, :status, :items, :rounds, :participants]
  defstruct [
    :id,
    :name,
    :host_token,
    :host_lv_pid,
    :host_monitor_ref,
    :status,
    :items,
    :rounds,
    :current_round,
    :current_matchup,
    :participants,
    :timer_seconds,
    :timer_ref,
    :created_at,
    :last_activity_at
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new game. Validates inputs, seeds the bracket, adds the host as
  the first participant.

  Returns `{:ok, %Game{}}` or `{:error, reason}`.
  """
  @spec new(String.t(), [String.t()], String.t()) ::
          {:ok, %__MODULE__{}} | {:error, atom()}
  def new(name, items, host_name, opts \\ []) do
    sanitized_name = Sanitizer.sanitize(name, 100)
    sanitized_items = Sanitizer.sanitize_items(items)

    with :ok <- validate_name(sanitized_name),
         :ok <- validate_items(sanitized_items) do
      shuffle = Keyword.get(opts, :shuffle, true)

      padded_items = build_padded_items(sanitized_items, shuffle)
      rounds = build_initial_rounds(padded_items)
      now = DateTime.utc_now()
      id = generate_id()
      host_token = Base.encode64(:crypto.strong_rand_bytes(32))

      game = %__MODULE__{
        id: id,
        name: sanitized_name,
        host_token: host_token,
        host_lv_pid: nil,
        host_monitor_ref: nil,
        status: :lobby,
        items: padded_items,
        rounds: rounds,
        current_round: nil,
        current_matchup: nil,
        participants: %{},
        timer_seconds: nil,
        timer_ref: nil,
        created_at: now,
        last_activity_at: now
      }

      sanitized_host_name = Sanitizer.sanitize(host_name, 30)
      {game, _participant_id} = do_add_participant(game, sanitized_host_name, nil, true)

      {:ok, game}
    end
  end

  @doc """
  Returns a sanitized copy of the game safe to broadcast to clients.
  Strips host_token, host_monitor_ref, timer_ref, and individual votes.
  """
  @spec public_view(%__MODULE__{}) :: %__MODULE__{}
  def public_view(%__MODULE__{} = game) do
    sanitized_rounds =
      Enum.map(game.rounds, fn round ->
        sanitized_matchups =
          Enum.map(round.matchups, fn matchup ->
            eligible_count = count_eligible_voters(game, matchup.id)

            count_a =
              matchup.votes
              |> Map.values()
              |> Enum.count(&(&1 == :a))

            count_b =
              matchup.votes
              |> Map.values()
              |> Enum.count(&(&1 == :b))

            %{matchup | votes: %{count_a: count_a, count_b: count_b, total_eligible: eligible_count}}
          end)

        %{round | matchups: sanitized_matchups}
      end)

    %{game | host_token: nil, host_monitor_ref: nil, timer_ref: nil, rounds: sanitized_rounds}
  end

  @doc """
  Adds a participant to the game.

  Returns `{:ok, {game, participant_id}}` or `{:error, reason}`.
  """
  @spec add_participant(%__MODULE__{}, String.t(), pid() | nil) ::
          {:ok, {%__MODULE__{}, String.t()}} | {:error, atom()}
  def add_participant(%__MODULE__{} = game, display_name, lv_pid) do
    if map_size(game.participants) >= 50 do
      {:error, :bracket_full}
    else
      sanitized_name = Sanitizer.sanitize(display_name, 30)
      {updated_game, participant_id} = do_add_participant(game, sanitized_name, lv_pid, false)
      {:ok, {updated_game, participant_id}}
    end
  end

  @doc """
  Transitions the game from `:lobby` to `:active`.

  Returns `{:ok, game}` or `{:error, reason}`.
  """
  @spec start_bracket(%__MODULE__{}, String.t()) ::
          {:ok, %__MODULE__{}} | {:error, atom()}
  def start_bracket(%__MODULE__{} = game, host_token) do
    with :ok <- verify_host_token(game, host_token),
         :ok <- require_status(game, :lobby) do
      game =
        game
        |> Map.put(:status, :active)
        |> Map.put(:current_round, 0)
        |> advance_to_first_active_matchup()
        |> touch()

      {:ok, game}
    end
  end

  @doc """
  Records a vote from `participant_id` on `matchup_id`.

  Returns `{:ok, game}` or `{:error, reason}`.
  """
  @spec record_vote(%__MODULE__{}, String.t(), non_neg_integer(), :a | :b) ::
          {:ok, %__MODULE__{}} | {:error, atom()}
  def record_vote(%__MODULE__{} = game, participant_id, matchup_id, choice)
      when choice in [:a, :b] do
    with :ok <- require_not_finished(game),
         {:ok, participant} <- fetch_participant(game, participant_id),
         :ok <- verify_eligible(participant, matchup_id),
         {:ok, matchup} <- fetch_active_matchup(game, matchup_id) do
      updated_votes = Map.put(matchup.votes, participant_id, choice)
      updated_matchup = %{matchup | votes: updated_votes}
      game = put_matchup(game, updated_matchup) |> touch()
      {:ok, game}
    end
  end

  @doc """
  Closes the current active matchup and determines the winner.

  Returns `{:ok, game, was_tie_breaker}`.
  """
  @spec close_matchup(%__MODULE__{}) ::
          {:ok, %__MODULE__{}, boolean()}
  def close_matchup(%__MODULE__{} = game) do
    matchup = get_current_matchup(game)

    eligible_votes =
      matchup.votes
      |> Enum.filter(fn {pid, _choice} -> voter_eligible?(game, pid, matchup.id) end)

    count_a = Enum.count(eligible_votes, fn {_, c} -> c == :a end)
    count_b = Enum.count(eligible_votes, fn {_, c} -> c == :b end)

    {winner, was_tie_breaker} =
      cond do
        count_a > count_b ->
          {matchup.item_a, false}

        count_b > count_a ->
          {matchup.item_b, false}

        true ->
          # Tie or no votes: check host vote
          host_id = find_host_id(game)
          host_vote = if host_id, do: Map.get(matchup.votes, host_id), else: nil

          case host_vote do
            :a -> {matchup.item_a, true}
            :b -> {matchup.item_b, true}
            _ -> {random_winner(matchup), true}
          end
      end

    closed_matchup = %{matchup | winner: winner, status: :closed}
    game = put_matchup(game, closed_matchup) |> touch()
    game = advance_after_close(game)

    {:ok, game, was_tie_breaker}
  end

  @doc """
  Removes a participant from the game and cleans up their active vote.

  Returns `{:ok, game}`.
  """
  @spec remove_participant(%__MODULE__{}, String.t()) :: {:ok, %__MODULE__{}}
  def remove_participant(%__MODULE__{} = game, participant_id) do
    game =
      game
      |> remove_vote_from_active_matchup(participant_id)
      |> Map.update!(:participants, &Map.delete(&1, participant_id))
      |> touch()

    {:ok, game}
  end

  @doc """
  Restarts the bracket: re-shuffles items, rebuilds rounds, resets to `:lobby`.
  Keeps all participants with `eligible_from_matchup` reset to nil.
  """
  @spec restart(%__MODULE__{}, String.t()) :: {:ok, %__MODULE__{}} | {:error, atom()}
  def restart(%__MODULE__{} = game, host_token) do
    with :ok <- verify_host_token(game, host_token) do
      padded_items = build_padded_items(Enum.reject(game.items, &is_nil/1), true)
      rounds = build_initial_rounds(padded_items)

      reset_participants =
        Map.new(game.participants, fn {id, p} ->
          {id, %{p | eligible_from_matchup: nil}}
        end)

      now = DateTime.utc_now()

      game = %{
        game
        | status: :lobby,
          items: padded_items,
          rounds: rounds,
          current_round: nil,
          current_matchup: nil,
          participants: reset_participants,
          timer_ref: nil,
          last_activity_at: now
      }

      {:ok, game}
    end
  end

  @doc """
  Transfers host status to a new participant. Generates a new host_token.

  Returns `{:ok, game, new_host_token}`.
  """
  @spec transfer_host(%__MODULE__{}, String.t()) ::
          {:ok, %__MODULE__{}, String.t()}
  def transfer_host(%__MODULE__{} = game, new_participant_id) do
    new_host_token = Base.encode64(:crypto.strong_rand_bytes(32))

    updated_participants =
      Map.new(game.participants, fn {id, p} ->
        cond do
          id == new_participant_id -> {id, %{p | is_host: true}}
          p.is_host -> {id, %{p | is_host: false}}
          true -> {id, p}
        end
      end)

    game = %{game | host_token: new_host_token, participants: updated_participants} |> touch()

    {:ok, game, new_host_token}
  end

  @doc """
  Sets the timer duration for matchups. Must be between 5 and 300 seconds.
  Returns `{:ok, game}` or `{:error, :invalid_timer}`.
  """
  @spec set_timer(%__MODULE__{}, pos_integer() | nil) ::
          {:ok, %__MODULE__{}} | {:error, atom()}
  def set_timer(%__MODULE__{} = game, nil) do
    {:ok, %{game | timer_seconds: nil} |> touch()}
  end

  def set_timer(%__MODULE__{} = game, seconds)
      when is_integer(seconds) and seconds >= 5 and seconds <= 300 do
    {:ok, %{game | timer_seconds: seconds} |> touch()}
  end

  def set_timer(%__MODULE__{}, _), do: {:error, :invalid_timer}

  @doc """
  Returns the next power of 2 that is >= n.
  """
  @spec next_power_of_two(pos_integer()) :: pos_integer()
  def next_power_of_two(n) when n <= 1, do: 1

  def next_power_of_two(n) do
    :math.pow(2, :math.ceil(:math.log2(n))) |> trunc()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_name(""), do: {:error, :invalid_name}
  defp validate_name(name) when byte_size(name) > 100, do: {:error, :invalid_name}
  defp validate_name(_), do: :ok

  defp validate_items(items) when length(items) < 4, do: {:error, :too_few_items}
  defp validate_items(items) when length(items) > 32, do: {:error, :too_many_items}
  defp validate_items(_), do: :ok

  defp generate_id do
    :crypto.strong_rand_bytes(6)
    |> Base.encode64()
    |> binary_part(0, 8)
  end

  defp generate_participant_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp build_padded_items(items, shuffle) do
    items = if shuffle, do: Enum.shuffle(items), else: items
    size = next_power_of_two(length(items))
    n_byes = size - length(items)

    # Distribute byes evenly: first n_byes items each get a bye (paired with nil),
    # then remaining items are paired with each other. This avoids (nil,nil) matchups
    # and ensures byes are spread across the bracket rather than bunched at the end.
    {bye_items, real_items} = Enum.split(items, n_byes)
    Enum.flat_map(bye_items, fn item -> [item, nil] end) ++ real_items
  end

  defp build_initial_rounds(padded_items) do
    matchups =
      padded_items
      |> Enum.chunk_every(2)
      |> Enum.with_index()
      |> Enum.map(fn {[item_a, item_b], idx} ->
        matchup = %Matchup{
          id: idx,
          item_a: item_a,
          item_b: item_b,
          votes: %{},
          winner: nil,
          status: :pending
        }

        auto_close_bye(matchup)
      end)

    [%Round{matchups: matchups}]
  end

  defp auto_close_bye(%Matchup{item_a: nil, item_b: item_b} = m) when not is_nil(item_b) do
    %{m | status: :closed, winner: item_b}
  end

  defp auto_close_bye(%Matchup{item_a: item_a, item_b: nil} = m) when not is_nil(item_a) do
    %{m | status: :closed, winner: item_a}
  end

  defp auto_close_bye(%Matchup{item_a: nil, item_b: nil} = m) do
    # Both nil shouldn't happen but handle gracefully
    %{m | status: :closed, winner: nil}
  end

  defp auto_close_bye(m), do: m

  defp do_add_participant(game, display_name, lv_pid, is_host) do
    unique_name = unique_display_name(game, display_name)
    participant_id = generate_participant_id()
    now = DateTime.utc_now()

    eligible_from =
      if game.status == :active do
        (game.current_matchup || 0) + 1
      else
        nil
      end

    participant = %Participant{
      id: participant_id,
      display_name: unique_name,
      lv_pid: lv_pid,
      connected: true,
      joined_at: now,
      eligible_from_matchup: eligible_from,
      is_host: is_host
    }

    updated_participants = Map.put(game.participants, participant_id, participant)

    updated_game =
      game
      |> Map.put(:participants, updated_participants)
      |> touch()

    {updated_game, participant_id}
  end

  defp unique_display_name(game, name) do
    existing_names =
      game.participants
      |> Map.values()
      |> Enum.map(& &1.display_name)
      |> MapSet.new()

    if MapSet.member?(existing_names, name) do
      find_unique_suffix(name, existing_names, 2)
    else
      name
    end
  end

  defp find_unique_suffix(base, existing, suffix) do
    candidate = "#{base} #{suffix}"

    if MapSet.member?(existing, candidate) do
      find_unique_suffix(base, existing, suffix + 1)
    else
      candidate
    end
  end

  defp verify_host_token(%__MODULE__{host_token: token}, token), do: :ok
  defp verify_host_token(_, _), do: {:error, :unauthorized}

  defp require_status(%__MODULE__{status: status}, status), do: :ok

  defp require_status(%__MODULE__{status: _actual}, :lobby), do: {:error, :not_in_lobby}
  defp require_status(%__MODULE__{status: _actual}, _expected), do: {:error, :wrong_status}

  defp require_not_finished(%__MODULE__{status: :finished}), do: {:error, :bracket_finished}
  defp require_not_finished(_), do: :ok

  defp fetch_participant(%__MODULE__{participants: participants}, participant_id) do
    case Map.fetch(participants, participant_id) do
      {:ok, p} -> {:ok, p}
      :error -> {:error, :not_a_participant}
    end
  end

  defp verify_eligible(%Participant{eligible_from_matchup: nil}, _matchup_id), do: :ok

  defp verify_eligible(%Participant{eligible_from_matchup: from}, matchup_id)
       when matchup_id >= from,
       do: :ok

  defp verify_eligible(_, _), do: {:error, :not_eligible}

  defp fetch_active_matchup(%__MODULE__{current_matchup: current} = game, matchup_id) do
    if matchup_id != current do
      {:error, :matchup_not_active}
    else
      matchup = get_current_matchup(game)

      if matchup && matchup.status == :active do
        {:ok, matchup}
      else
        {:error, :matchup_not_active}
      end
    end
  end

  defp get_current_matchup(%__MODULE__{rounds: rounds, current_round: round_idx, current_matchup: matchup_idx})
       when is_integer(round_idx) and is_integer(matchup_idx) do
    round = Enum.at(rounds, round_idx)
    if round, do: Enum.find(round.matchups, &(&1.id == matchup_idx)), else: nil
  end

  defp get_current_matchup(_), do: nil

  defp put_matchup(%__MODULE__{} = game, updated_matchup) do
    updated_rounds =
      Enum.map(game.rounds, fn round ->
        updated_matchups =
          Enum.map(round.matchups, fn m ->
            if m.id == updated_matchup.id and round == Enum.at(game.rounds, game.current_round),
              do: updated_matchup,
              else: m
          end)

        %{round | matchups: updated_matchups}
      end)

    %{game | rounds: updated_rounds}
  end

  defp advance_to_first_active_matchup(%__MODULE__{} = game) do
    round = Enum.at(game.rounds, game.current_round)

    case Enum.find(round.matchups, &(&1.status == :pending)) do
      nil ->
        # All matchups in this round are byes — shouldn't normally happen with 4+ items
        game

      matchup ->
        updated_matchup = %{matchup | status: :active}
        game = put_matchup_in_round(game, game.current_round, updated_matchup)
        %{game | current_matchup: matchup.id}
    end
  end

  defp advance_after_close(%__MODULE__{} = game) do
    round = Enum.at(game.rounds, game.current_round)
    remaining = Enum.find(round.matchups, &(&1.status == :pending))

    if remaining do
      # Advance to next pending matchup in current round
      updated_matchup = %{remaining | status: :active}
      game = put_matchup_in_round(game, game.current_round, updated_matchup)
      %{game | current_matchup: remaining.id}
    else
      # All matchups in current round closed — check if we need a new round
      winners = Enum.map(round.matchups, & &1.winner) |> Enum.reject(&is_nil/1)

      if length(winners) == 1 do
        # Champion!
        %{game | status: :finished}
      else
        # Build next round
        next_round_idx = game.current_round + 1
        next_matchups = build_next_round_matchups(round.matchups)
        next_round = %Round{matchups: next_matchups}

        updated_rounds = game.rounds ++ [next_round]
        game = %{game | rounds: updated_rounds, current_round: next_round_idx}

        # Find first non-closed matchup in new round (handle byes)
        case Enum.find(next_matchups, &(&1.status == :pending)) do
          nil ->
            # All byes in new round — recurse
            advance_after_close(game)

          matchup ->
            updated_matchup = %{matchup | status: :active}
            game = put_matchup_in_round(game, next_round_idx, updated_matchup)
            %{game | current_matchup: matchup.id}
        end
      end
    end
  end

  defp build_next_round_matchups(prev_matchups) do
    all_winners =
      prev_matchups
      |> Enum.map(& &1.winner)
      |> Enum.reject(&is_nil/1)

    # Pad to even count so chunk_every(2) never produces a singleton
    padded =
      if rem(length(all_winners), 2) == 1 do
        all_winners ++ [nil]
      else
        all_winners
      end

    padded
    |> Enum.chunk_every(2)
    |> Enum.with_index()
    |> Enum.map(fn {[item_a, item_b], idx} ->
      matchup = %Matchup{
        id: idx,
        item_a: item_a,
        item_b: item_b,
        votes: %{},
        winner: nil,
        status: :pending
      }

      auto_close_bye(matchup)
    end)
  end

  defp put_matchup_in_round(%__MODULE__{} = game, round_idx, updated_matchup) do
    updated_rounds =
      game.rounds
      |> Enum.with_index()
      |> Enum.map(fn {round, idx} ->
        if idx == round_idx do
          updated_matchups =
            Enum.map(round.matchups, fn m ->
              if m.id == updated_matchup.id, do: updated_matchup, else: m
            end)

          %{round | matchups: updated_matchups}
        else
          round
        end
      end)

    %{game | rounds: updated_rounds}
  end

  defp remove_vote_from_active_matchup(%__MODULE__{} = game, participant_id) do
    case get_current_matchup(game) do
      %Matchup{status: :active} = matchup ->
        updated_votes = Map.delete(matchup.votes, participant_id)
        updated_matchup = %{matchup | votes: updated_votes}
        put_matchup_in_round(game, game.current_round, updated_matchup)

      _ ->
        game
    end
  end

  defp count_eligible_voters(%__MODULE__{participants: participants}, matchup_id) do
    Enum.count(participants, fn {_, p} ->
      p.eligible_from_matchup == nil or p.eligible_from_matchup <= matchup_id
    end)
  end

  defp voter_eligible?(%__MODULE__{participants: participants}, participant_id, matchup_id) do
    case Map.fetch(participants, participant_id) do
      {:ok, %Participant{eligible_from_matchup: nil}} -> true
      {:ok, %Participant{eligible_from_matchup: from}} -> matchup_id >= from
      :error -> false
    end
  end

  defp find_host_id(%__MODULE__{participants: participants}) do
    case Enum.find(participants, fn {_, p} -> p.is_host end) do
      {id, _} -> id
      nil -> nil
    end
  end

  defp random_winner(%Matchup{item_a: item_a, item_b: item_b}) do
    [item_a, item_b]
    |> Enum.reject(&is_nil/1)
    |> Enum.random()
  end

  defp touch(%__MODULE__{} = game) do
    %{game | last_activity_at: DateTime.utc_now()}
  end
end
