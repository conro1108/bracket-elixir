defmodule Bracket.BracketServer do
  @moduledoc """
  GenServer that holds the state of a single bracket game.

  Uses `restart: :transient` so that normal exits (bracket finished or
  cleaned up) do not cause DynamicSupervisor to respawn it.

  All state mutations call pure functions in `Bracket.Game`, then broadcast
  the sanitized public view via `Bracket.PubSub`.
  """

  use GenServer, restart: :transient

  alias Bracket.Game
  require Logger

  @pubsub Bracket.PubSub

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc "Creates and registers a new bracket. Returns {:ok, id, host_token} or {:error, reason}."
  def create(%{name: name, items: items, host_name: host_name} = _attrs) do
    case Game.new(name, items, host_name) do
      {:ok, game} ->
        spec = {__MODULE__, game}

        case DynamicSupervisor.start_child(Bracket.DynamicSupervisor, spec) do
          {:ok, _pid} -> {:ok, game.id, game.host_token}
          {:error, :max_children} -> {:error, :too_many_brackets}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Returns the public (sanitized) game state. Returns {:ok, game} or {:error, :not_found}."
  def get_state(id) do
    call(id, :get_state)
  end

  @doc """
  Joins a bracket as a participant. If `opts[:host_token]` is present and valid,
  the joining participant is promoted to host (host reconnect flow).

  Returns {:ok, participant_id} or {:error, reason}.
  """
  def join(id, display_name, lv_pid, opts \\ []) do
    call(id, {:join, display_name, lv_pid, opts})
  end

  @doc "Records a vote. Fire-and-forget cast — no return value."
  def vote(id, participant_id, matchup_id, choice) do
    cast(id, {:vote, participant_id, matchup_id, choice})
  end

  @doc "Starts the bracket (host only). Returns :ok or {:error, reason}."
  def start_bracket(id, host_token) do
    call(id, {:start_bracket, host_token})
  end

  @doc "Closes the current matchup early (host only). Returns :ok or {:error, reason}."
  def close_matchup(id, host_token) do
    call(id, {:close_matchup, host_token})
  end

  @doc "Kicks a participant (host only). Returns :ok or {:error, reason}."
  def kick(id, host_token, participant_id) do
    call(id, {:kick, host_token, participant_id})
  end

  @doc "Restarts the bracket (host only). Returns :ok or {:error, reason}."
  def restart(id, host_token) do
    call(id, {:restart, host_token})
  end

  @doc "Sets the matchup timer duration (host only). Returns :ok or {:error, reason}."
  def set_timer(id, host_token, seconds) do
    call(id, {:set_timer, host_token, seconds})
  end

  @doc "Validates that a token is the correct host token. Returns :ok or {:error, :unauthorized}."
  def validate_host_token(id, token) do
    call(id, {:validate_host_token, token})
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  def start_link(%Game{id: id} = game) do
    GenServer.start_link(__MODULE__, game, name: via(id))
  end

  def child_spec(%Game{} = game) do
    %{
      id: {__MODULE__, game.id},
      start: {__MODULE__, :start_link, [game]},
      restart: :transient
    }
  end

  @impl true
  def init(%Game{} = game) do
    {:ok, game, {:continue, :schedule_cleanup}}
  end

  @impl true
  def handle_continue(:schedule_cleanup, state) do
    interval = Application.get_env(:bracket, :cleanup_interval, 5 * 60 * 1000)
    Process.send_after(self(), :check_activity, interval)
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # handle_call implementations
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, Game.public_view(state)}, state}
  end

  def handle_call({:join, display_name, lv_pid, opts}, _from, state) do
    host_token = Keyword.get(opts, :host_token)

    case try_join(state, display_name, lv_pid, host_token) do
      {:ok, {updated_game, participant_id}} ->
        updated_game = maybe_remonitor_host(state, updated_game, participant_id, host_token)
        broadcast_event(updated_game, :participant_joined)
        {:reply, {:ok, participant_id}, updated_game}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:start_bracket, host_token}, _from, state) do
    case Game.start_bracket(state, host_token) do
      {:ok, game} ->
        game = maybe_start_timer(game)
        broadcast_event(game, :bracket_started)
        {:reply, :ok, game}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:close_matchup, host_token}, _from, state) do
    with :ok <- verify_host_token_call(state, host_token) do
      do_close_matchup(state)
    else
      err -> {:reply, err, state}
    end
  end

  def handle_call({:kick, host_token, participant_id}, _from, state) do
    with :ok <- verify_host_token_call(state, host_token) do
      {:ok, game} = Game.remove_participant(state, participant_id)
      Phoenix.PubSub.broadcast(@pubsub, topic(game.id), {:bracket_event, :kicked, participant_id})
      broadcast_event(game, :participant_left)
      {:reply, :ok, game}
    else
      err -> {:reply, err, state}
    end
  end

  def handle_call({:restart, host_token}, _from, state) do
    case Game.restart(state, host_token) do
      {:ok, game} ->
        broadcast_event(game, :bracket_restarted)
        {:reply, :ok, game}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_timer, host_token, seconds}, _from, state) do
    with :ok <- verify_host_token_call(state, host_token) do
      case Game.set_timer(state, seconds) do
        {:ok, game} -> {:reply, :ok, game}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      err -> {:reply, err, state}
    end
  end

  def handle_call({:validate_host_token, token}, _from, state) do
    result = verify_host_token_call(state, token)
    {:reply, result, state}
  end

  # ---------------------------------------------------------------------------
  # handle_cast implementations
  # ---------------------------------------------------------------------------

  @impl true
  def handle_cast({:vote, participant_id, matchup_id, choice}, state) do
    case Game.record_vote(state, participant_id, matchup_id, choice) do
      {:ok, game} ->
        matchup = get_matchup_by_id(game, game.current_round, game.current_matchup)
        eligible = count_eligible(game, matchup)
        voted = map_size(matchup.votes)

        vote_counts = compute_vote_counts(matchup)

        Phoenix.PubSub.broadcast(
          @pubsub,
          topic(game.id),
          {:vote_update, matchup_id, vote_counts.count_a, vote_counts.count_b, eligible}
        )

        if voted >= eligible and eligible > 0 do
          # Auto-close when all eligible voters have voted
          case do_close_matchup_state(game) do
            {:ok, closed_game, reply_tuple} ->
              {:noreply, closed_game}
              # We ignore the reply_tuple since this is a cast
              |> tap(fn _ ->
                send_close_broadcasts(closed_game, reply_tuple)
              end)

            _ ->
              {:noreply, game}
          end
        else
          {:noreply, game}
        end

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  # ---------------------------------------------------------------------------
  # handle_info implementations
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:timer_expired, matchup_id}, state) do
    # Stale timer check: only process if still on this matchup and it's active
    current_matchup = get_matchup_by_id(state, state.current_round, state.current_matchup)

    if current_matchup && current_matchup.id == matchup_id && current_matchup.status == :active do
      case do_close_matchup_state(state) do
        {:ok, game, reply_tuple} ->
          send_close_broadcasts(game, reply_tuple)
          {:noreply, game}

        _ ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(:host_transfer_warning, state) do
    # Warn participants that host is disconnected
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(state.id),
      {:bracket_event, :host_disconnect_warning, Game.public_view(state)}
    )

    transfer_ms =
      Application.get_env(:bracket, :host_disconnect_transfer_ms, 60_000)

    Process.send_after(self(), :host_transfer, transfer_ms)
    {:noreply, state}
  end

  def handle_info(:host_transfer, state) do
    # Find the longest-tenured non-host participant
    case find_longest_tenured_non_host(state) do
      nil ->
        # No other participants — nothing to do
        {:noreply, state}

      new_host_id ->
        {:ok, game, new_host_token} = Game.transfer_host(state, new_host_id)

        Phoenix.PubSub.broadcast(
          @pubsub,
          topic(game.id),
          {:bracket_event, :host_transferred, new_host_id, new_host_token, Game.public_view(game)}
        )

        {:noreply, game}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # Host's LiveView process went down
    if state.host_monitor_ref == ref do
      warning_ms =
        Application.get_env(:bracket, :host_disconnect_warning_ms, 30_000)

      Process.send_after(self(), :host_transfer_warning, warning_ms)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:check_activity, state) do
    threshold_ms =
      Application.get_env(:bracket, :cleanup_inactive_threshold, 4 * 60 * 60 * 1000)

    diff_ms = DateTime.diff(DateTime.utc_now(), state.last_activity_at, :millisecond)

    if diff_ms > threshold_ms do
      {:stop, :normal, state}
    else
      # Reschedule
      interval = Application.get_env(:bracket, :cleanup_interval, 5 * 60 * 1000)
      Process.send_after(self(), :check_activity, interval)
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp via(id), do: {:via, Registry, {Bracket.Registry, id}}

  defp topic(id), do: "bracket:#{id}"

  defp call(id, msg) do
    case Registry.lookup(Bracket.Registry, id) do
      [{pid, _}] ->
        GenServer.call(pid, msg)

      [] ->
        {:error, :not_found}
    end
  end

  defp cast(id, msg) do
    case Registry.lookup(Bracket.Registry, id) do
      [{pid, _}] -> GenServer.cast(pid, msg)
      [] -> :ok
    end
  end

  defp broadcast_event(game, event_type) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(game.id),
      {:bracket_event, event_type, Game.public_view(game)}
    )
  end

  defp verify_host_token_call(%Game{host_token: token}, token), do: :ok
  defp verify_host_token_call(_, _), do: {:error, :unauthorized}

  defp try_join(state, display_name, lv_pid, host_token) do
    # If this is a host reconnect (host_token matches), just update PID
    existing_host_id = find_host_id_if_matching(state, host_token)

    if existing_host_id do
      # Host reconnect: update pid and connected flag
      updated_participants =
        Map.update!(state.participants, existing_host_id, fn p ->
          %{p | lv_pid: lv_pid, connected: true}
        end)

      updated_game = %{state | participants: updated_participants, host_lv_pid: lv_pid}
      {:ok, {updated_game, existing_host_id}}
    else
      Game.add_participant(state, display_name, lv_pid)
    end
  end

  defp find_host_id_if_matching(game, host_token) when is_binary(host_token) do
    if game.host_token == host_token do
      case Enum.find(game.participants, fn {_, p} -> p.is_host end) do
        {id, _} -> id
        nil -> nil
      end
    end
  end

  defp find_host_id_if_matching(_, _), do: nil

  defp maybe_remonitor_host(old_state, game, participant_id, host_token)
       when is_binary(host_token) do
    if game.host_token == host_token do
      # Cancel any pending transfer timer by ignoring — we can't cancel named timers
      # The :host_transfer_warning and :host_transfer handlers will check current state.
      # Demonitor old ref
      if old_state.host_monitor_ref do
        Process.demonitor(old_state.host_monitor_ref, [:flush])
      end

      participant = Map.get(game.participants, participant_id)
      new_ref = if participant && participant.lv_pid, do: Process.monitor(participant.lv_pid)

      %{game | host_lv_pid: participant && participant.lv_pid, host_monitor_ref: new_ref}
    else
      game
    end
  end

  defp maybe_remonitor_host(_old_state, game, _participant_id, _host_token), do: game

  defp maybe_start_timer(%Game{timer_seconds: nil} = game), do: game

  defp maybe_start_timer(%Game{timer_seconds: seconds} = game) when is_integer(seconds) do
    cancel_timer(game)
    matchup_id = game.current_matchup
    ref = Process.send_after(self(), {:timer_expired, matchup_id}, seconds * 1000)
    %{game | timer_ref: ref}
  end

  defp cancel_timer(%Game{timer_ref: nil}), do: :ok

  defp cancel_timer(%Game{timer_ref: ref}) do
    Process.cancel_timer(ref)
    :ok
  end

  defp do_close_matchup(%Game{} = state) do
    cancel_timer(state)

    case do_close_matchup_state(state) do
      {:ok, game, {event, was_tie}} ->
        send_close_broadcasts(game, {event, was_tie})
        {:reply, :ok, game}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp do_close_matchup_state(%Game{} = state) do
    case Game.close_matchup(state) do
      {:ok, game, was_tie_breaker} ->
        cancel_timer(state)

        event =
          cond do
            game.status == :finished -> :bracket_champion
            game.current_round > state.current_round -> :round_complete
            true -> :matchup_closed
          end

        # Start timer for next matchup if applicable
        game = if game.status == :active, do: maybe_start_timer(game), else: game

        {:ok, game, {event, was_tie_breaker}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_close_broadcasts(game, {event, _was_tie}) do
    broadcast_event(game, event)
  end

  defp get_matchup_by_id(_game, nil, _matchup_id), do: nil
  defp get_matchup_by_id(_game, _round_idx, nil), do: nil

  defp get_matchup_by_id(game, round_idx, matchup_id) do
    with round when not is_nil(round) <- Enum.at(game.rounds, round_idx) do
      Enum.find(round.matchups, &(&1.id == matchup_id))
    end
  end

  defp count_eligible(game, matchup) when not is_nil(matchup) do
    Enum.count(game.participants, fn {_, p} ->
      p.eligible_from_matchup == nil or p.eligible_from_matchup <= matchup.id
    end)
  end

  defp count_eligible(_game, nil), do: 0

  defp compute_vote_counts(matchup) when not is_nil(matchup) do
    count_a = Enum.count(matchup.votes, fn {_, v} -> v == :a end)
    count_b = Enum.count(matchup.votes, fn {_, v} -> v == :b end)
    %{count_a: count_a, count_b: count_b}
  end

  defp compute_vote_counts(nil), do: %{count_a: 0, count_b: 0}

  defp find_longest_tenured_non_host(game) do
    game.participants
    |> Enum.reject(fn {_, p} -> p.is_host end)
    |> Enum.min_by(fn {_, p} -> p.joined_at end, DateTime, fn -> nil end)
    |> case do
      {id, _} -> id
      nil -> nil
    end
  end
end
