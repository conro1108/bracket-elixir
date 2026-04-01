defmodule BracketWeb.BracketLive do
  use BracketWeb, :live_view

  import BracketWeb.Components.BracketTree

  @impl true
  def mount(%{"id" => id} = params, session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Bracket.PubSub, "bracket:#{id}")

      case Bracket.BracketServer.get_state(id) do
        {:ok, game} ->
          participant_id = session["participant_id_#{id}"]
          host_token = session["host_token"] || params["token"]

          phase = determine_phase(game, participant_id, host_token)

          # Re-register host LiveView PID on reconnect
          if host_token && participant_id do
            Bracket.BracketServer.join(id, nil, self(),
              participant_id: participant_id,
              host_token: host_token
            )
          end

          {:ok,
           assign(socket,
             page_title: game.name,
             game: game,
             phase: phase,
             participant_id: participant_id,
             is_host: host_token != nil,
             host_token: host_token,
             bracket_id: id,
             show_bracket_panel: false,
             join_name: "",
             join_error: nil,
             my_vote: nil
           )}

        {:error, :not_found} ->
          {:ok,
           assign(socket,
             page_title: "Bracket Not Found",
             phase: :not_found,
             bracket_id: id,
             game: nil,
             participant_id: nil,
             is_host: false,
             host_token: nil,
             show_bracket_panel: false,
             join_name: "",
             join_error: nil,
             my_vote: nil
           )}
      end
    else
      {:ok,
       assign(socket,
         page_title: "Bracket",
         phase: :connecting,
         bracket_id: id,
         game: nil,
         participant_id: nil,
         is_host: false,
         host_token: nil,
         show_bracket_panel: false,
         join_name: "",
         join_error: nil,
         my_vote: nil
       )}
    end
  end

  # Host recovery route — validate token from query params, store in session via
  # the SessionController, then redirect to the bracket page.
  @impl true
  def handle_params(%{"token" => token}, _uri, socket) do
    id = socket.assigns.bracket_id

    case Bracket.BracketServer.validate_host_token(id, token) do
      :ok ->
        signed =
          Phoenix.Token.sign(socket, "host_session", %{"id" => id, "token" => token})

        {:noreply, redirect(socket, to: ~p"/session/host?session_token=#{signed}")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Invalid host recovery token.")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # ------------------- RENDER -------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="bracket-live" phx-hook="FocusManager" class="min-h-screen bg-base-100">
      {render_phase(assigns)}
      {render_bracket_panel(assigns)}
    </div>
    """
  end

  defp render_phase(%{phase: :connecting} = assigns) do
    ~H"""
    <div class="flex items-center justify-center min-h-screen">
      <div class="text-center space-y-4">
        <div class="skeleton-pulse w-48 h-8 mx-auto rounded-lg bg-base-300"></div>
        <div class="skeleton-pulse w-64 h-4 mx-auto rounded bg-base-300"></div>
        <span class="loading loading-spinner loading-lg text-primary mt-4"></span>
      </div>
    </div>
    """
  end

  defp render_phase(%{phase: :not_found} = assigns) do
    ~H"""
    <div class="flex items-center justify-center min-h-screen p-4">
      <div class="text-center space-y-4">
        <h1 class="text-3xl font-bold" tabindex="-1" data-focus-target>Bracket Not Found</h1>
        <p class="text-base-content/70">This bracket doesn't exist or has expired.</p>
        <.link navigate={~p"/"} class="btn btn-primary">Create a New Bracket</.link>
      </div>
    </div>
    """
  end

  defp render_phase(%{phase: :kicked} = assigns) do
    ~H"""
    <div class="flex items-center justify-center min-h-screen p-4">
      <div class="text-center space-y-4">
        <h1 class="text-3xl font-bold" tabindex="-1" data-focus-target>You Were Removed</h1>
        <p class="text-base-content/70">You were removed from this bracket by the host.</p>
        <.link navigate={~p"/"} class="btn btn-primary">Go Home</.link>
      </div>
    </div>
    """
  end

  defp render_phase(%{phase: :join_form} = assigns) do
    ~H"""
    <div class="flex items-center justify-center min-h-screen p-4">
      <div class="w-full max-w-sm">
        <div class="card bg-base-200 shadow-xl">
          <div class="card-body">
            <h1 class="text-2xl font-bold text-center" tabindex="-1" data-focus-target>
              {@game.name}
            </h1>
            <p class="text-center text-base-content/70 text-sm">Enter your name to join</p>

            <div class="fieldset mt-4">
              <label for="join-name" class="label mb-1">Display Name</label>
              <input
                id="join-name"
                type="text"
                name="join_name"
                value={@join_name}
                maxlength="30"
                placeholder="Your name"
                class={["w-full input", @join_error && "input-error"]}
                phx-change="update_join_name"
                phx-debounce="100"
                phx-keyup="join"
                phx-key="Enter"
                autofocus
              />
              <p :if={@join_error} class="mt-1 text-sm text-error">
                {@join_error}
              </p>
            </div>

            <button
              type="button"
              class="btn btn-primary w-full mt-2"
              disabled={String.trim(@join_name) == ""}
              phx-click="join"
            >
              Join Bracket
            </button>

            <p class="text-center text-xs text-base-content/50 mt-2">
              {map_size(@game.participants)} participant(s) waiting in lobby
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp render_phase(%{phase: :lobby} = assigns) do
    ~H"""
    <div class="max-w-xl mx-auto p-4 space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold" tabindex="-1" data-focus-target>{@game.name}</h1>
        <button
          type="button"
          class="btn btn-outline btn-sm"
          phx-click="toggle_bracket_panel"
        >
          View Bracket
        </button>
      </div>

      <%!-- Share URL --%>
      <div class="card bg-base-200">
        <div class="card-body p-4">
          <p class="text-sm font-semibold mb-2">Share this link:</p>
          <div class="flex gap-2">
            <input
              type="text"
              readonly
              value={bracket_url(@bracket_id)}
              class="flex-1 input input-sm text-xs"
              id="share-url"
            />
            <button
              type="button"
              class="btn btn-sm btn-outline"
              phx-click={JS.dispatch("bracket:copy_link", to: "#share-url")}
              aria-label="Copy share link"
            >
              <.icon name="hero-clipboard" class="size-4" />
            </button>
          </div>
        </div>
      </div>

      <%!-- Host recovery link --%>
      <details :if={@is_host} class="text-xs text-base-content/50">
        <summary class="cursor-pointer select-none">Host recovery link (bookmark this)</summary>
        <div class="mt-2 p-2 bg-base-200 rounded break-all">
          {host_recovery_url(@bracket_id, @host_token)}
        </div>
      </details>

      <%!-- Timer settings (host only) --%>
      <div :if={@is_host} class="card bg-base-200">
        <div class="card-body p-4">
          <p class="text-sm font-semibold mb-2">Timer Settings</p>
          <div class="flex items-center gap-3">
            <input
              type="checkbox"
              class="checkbox checkbox-sm"
              id="timer-enabled"
              checked={@game.timer_seconds != nil}
              phx-click="toggle_timer"
            />
            <label for="timer-enabled" class="text-sm">Enable timer</label>
            <input
              :if={@game.timer_seconds != nil}
              type="range"
              min="5"
              max="300"
              value={@game.timer_seconds || 60}
              class="range range-xs flex-1"
              phx-change="set_timer"
              phx-debounce="500"
            />
            <span :if={@game.timer_seconds != nil} class="text-xs w-12 text-right">
              {@game.timer_seconds}s
            </span>
          </div>
        </div>
      </div>

      <%!-- Timer info for participants --%>
      <div :if={!@is_host && @game.timer_seconds != nil} class="text-sm text-base-content/60 text-center">
        Timer: {@game.timer_seconds} seconds per matchup
      </div>

      <%!-- Participant list --%>
      <div class="card bg-base-200">
        <div class="card-body p-4">
          <p class="text-sm font-semibold mb-3">
            Participants ({map_size(@game.participants)})
          </p>
          <ul class="space-y-2">
            <%= for {_id, participant} <- @game.participants do %>
              <li class="flex items-center justify-between">
                <div class="flex items-center gap-2">
                  <span class={["w-2 h-2 rounded-full", if(participant.connected, do: "bg-success", else: "bg-base-300")]}></span>
                  <span class="text-sm">
                    {participant.display_name}
                    <span :if={participant.is_host} class="text-xs text-primary ml-1">(host)</span>
                    <span :if={participant.id == @participant_id} class="text-xs text-base-content/50 ml-1">(you)</span>
                  </span>
                </div>
                <button
                  :if={@is_host && !participant.is_host}
                  type="button"
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="kick"
                  phx-value-id={participant.id}
                  aria-label={"Kick #{participant.display_name}"}
                >
                  Remove
                </button>
              </li>
            <% end %>
          </ul>
        </div>
      </div>

      <%!-- Start button (host only) --%>
      <button
        :if={@is_host}
        type="button"
        class="btn btn-primary btn-lg w-full"
        phx-click="start"
      >
        Start Round 1
      </button>

      <p :if={!@is_host} class="text-center text-base-content/60 text-sm">
        Waiting for the host to start...
      </p>
    </div>
    """
  end

  defp render_phase(%{phase: :voting} = assigns) do
    current_matchup = current_matchup(assigns.game)

    assigns = assign(assigns, current_matchup: current_matchup)

    ~H"""
    <div class="max-w-xl mx-auto p-4 space-y-6">
      <%!-- Timer bar --%>
      {render_timer_bar(assigns)}

      <div class="flex items-center justify-between">
        <h1 class="text-xl font-bold" tabindex="-1" data-focus-target>
          Round {@game.current_round + 1} · Matchup {@game.current_matchup + 1}
        </h1>
        <button
          type="button"
          class="btn btn-outline btn-sm"
          phx-click="toggle_bracket_panel"
        >
          View Bracket
        </button>
      </div>

      <%!-- Vote progress --%>
      <div :if={@current_matchup} aria-live="polite" class="text-center text-sm text-base-content/60">
        {vote_count(@current_matchup)} of {eligible_count(@current_matchup)} voted
      </div>

      <%!-- Vote buttons --%>
      <div :if={@current_matchup} class="grid grid-cols-2 gap-4">
        <button
          type="button"
          class={[
            "vote-button flex flex-col items-center justify-center p-6 rounded-2xl border-2 transition-all min-h-[120px] text-center",
            voted_for?(@my_vote, "a") && "border-primary bg-primary/10 ring-2 ring-primary",
            !voted_for?(@my_vote, "a") && "border-base-300 bg-base-200 hover:border-primary/50"
          ]}
          aria-label={"Vote for #{@current_matchup.item_a}"}
          aria-pressed={to_string(voted_for?(@my_vote, "a"))}
          phx-click="vote"
          phx-value-choice="a"
          phx-value-matchup_id={@current_matchup.id}
        >
          <span :if={voted_for?(@my_vote, "a")} class="mb-2">
            <.icon name="hero-check-circle" class="size-6 text-primary" />
          </span>
          <span class="font-semibold text-lg">{@current_matchup.item_a}</span>
        </button>

        <button
          type="button"
          class={[
            "vote-button flex flex-col items-center justify-center p-6 rounded-2xl border-2 transition-all min-h-[120px] text-center",
            voted_for?(@my_vote, "b") && "border-primary bg-primary/10 ring-2 ring-primary",
            !voted_for?(@my_vote, "b") && "border-base-300 bg-base-200 hover:border-primary/50"
          ]}
          aria-label={"Vote for #{@current_matchup.item_b}"}
          aria-pressed={to_string(voted_for?(@my_vote, "b"))}
          phx-click="vote"
          phx-value-choice="b"
          phx-value-matchup_id={@current_matchup.id}
        >
          <span :if={voted_for?(@my_vote, "b")} class="mb-2">
            <.icon name="hero-check-circle" class="size-6 text-primary" />
          </span>
          <span class="font-semibold text-lg">{@current_matchup.item_b}</span>
        </button>
      </div>

      <%!-- Host close matchup --%>
      <button
        :if={@is_host}
        type="button"
        class="btn btn-warning btn-sm w-full"
        phx-click="close_matchup"
      >
        Close Matchup Early
      </button>

      <%!-- Participant list --%>
      {render_participants(assigns)}
    </div>
    """
  end

  defp render_phase(%{phase: :waiting} = assigns) do
    current_matchup = current_matchup(assigns.game)
    assigns = assign(assigns, current_matchup: current_matchup)

    ~H"""
    <div class="max-w-xl mx-auto p-4 space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-xl font-bold" tabindex="-1" data-focus-target>
          Round {@game.current_round + 1} · Matchup {@game.current_matchup + 1}
        </h1>
        <button
          type="button"
          class="btn btn-outline btn-sm"
          phx-click="toggle_bracket_panel"
        >
          View Bracket
        </button>
      </div>

      <div class="alert alert-info">
        <.icon name="hero-information-circle" class="size-5" />
        <span>You joined mid-round. You can vote starting next matchup.</span>
      </div>

      <%!-- Current matchup (read-only) --%>
      <div :if={@current_matchup} class="grid grid-cols-2 gap-4">
        <div class="flex flex-col items-center justify-center p-6 rounded-2xl border-2 border-base-300 bg-base-200 min-h-[120px] text-center opacity-75">
          <span class="font-semibold text-lg">{@current_matchup.item_a}</span>
        </div>
        <div class="flex flex-col items-center justify-center p-6 rounded-2xl border-2 border-base-300 bg-base-200 min-h-[120px] text-center opacity-75">
          <span class="font-semibold text-lg">{@current_matchup.item_b}</span>
        </div>
      </div>

      <div :if={@current_matchup} aria-live="polite" class="text-center text-sm text-base-content/60">
        {vote_count(@current_matchup)} of {eligible_count(@current_matchup)} voted
      </div>

      {render_participants(assigns)}
    </div>
    """
  end

  defp render_phase(%{phase: :champion} = assigns) do
    champion =
      case assigns.game do
        %{rounds: rounds} when rounds != [] ->
          last_round = List.last(rounds)

          case last_round.matchups do
            [%{winner: winner}] -> winner
            _ -> nil
          end

        _ ->
          nil
      end

    assigns = assign(assigns, champion: champion)

    ~H"""
    <div class="max-w-xl mx-auto p-4 space-y-6 text-center">
      <div class="flex justify-end">
        <button
          type="button"
          class="btn btn-outline btn-sm"
          phx-click="toggle_bracket_panel"
        >
          View Bracket
        </button>
      </div>

      <div class="py-8">
        <div class="text-6xl mb-4">🏆</div>
        <h1 class="text-3xl font-bold mb-2" tabindex="-1" data-focus-target>Champion!</h1>
        <p class="text-2xl font-semibold text-primary">{@champion}</p>
      </div>

      <div class="card bg-base-200">
        <div class="card-body">
          <.bracket_tree game={@game} />
        </div>
      </div>

      <button
        :if={@is_host}
        type="button"
        class="btn btn-outline btn-lg w-full"
        phx-click="restart"
      >
        Restart Bracket
      </button>
    </div>
    """
  end

  defp render_phase(%{phase: :finished} = assigns) do
    ~H"""
    <div class="max-w-xl mx-auto p-4 space-y-6">
      <h1 class="text-2xl font-bold text-center" tabindex="-1" data-focus-target>
        {@game.name} — Results
      </h1>

      <div class="card bg-base-200">
        <div class="card-body">
          <.bracket_tree game={@game} />
        </div>
      </div>

      <.link navigate={~p"/"} class="btn btn-outline w-full">Create a New Bracket</.link>
    </div>
    """
  end

  defp render_phase(assigns) do
    ~H"""
    <div class="flex items-center justify-center min-h-screen p-4">
      <div class="text-center">
        <span class="loading loading-spinner loading-lg text-primary"></span>
      </div>
    </div>
    """
  end

  defp render_timer_bar(%{game: %{timer_seconds: nil}} = assigns) do
    ~H""
  end

  defp render_timer_bar(assigns) do
    ~H"""
    <div
      role="timer"
      class="timer-bar h-2 bg-base-300 rounded-full overflow-hidden fixed top-0 left-0 right-0 z-40"
    >
      <div
        class="timer-bar-fill h-full bg-primary transition-all duration-1000"
        style={"--timer-duration: #{@game.timer_seconds}s"}
      ></div>
    </div>
    """
  end

  defp render_bracket_panel(%{show_bracket_panel: false} = assigns) do
    ~H""
  end

  defp render_bracket_panel(assigns) do
    ~H"""
    <div
      class="bracket-panel fixed inset-0 z-50 flex flex-col bg-base-100"
      role="dialog"
      aria-modal="true"
      aria-label="Bracket view"
    >
      <div class="flex items-center justify-between p-4 border-b border-base-300">
        <h2 class="text-lg font-bold">{@game && @game.name}</h2>
        <button
          type="button"
          class="btn btn-ghost btn-square"
          aria-label="Close bracket view"
          phx-click="toggle_bracket_panel"
          style="min-width: 44px; min-height: 44px;"
        >
          <.icon name="hero-x-mark" class="size-6" />
        </button>
      </div>
      <div class="flex-1 overflow-auto">
        <.bracket_tree :if={@game} game={@game} />
      </div>
    </div>
    """
  end

  defp render_participants(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body p-4">
        <p class="text-sm font-semibold mb-3">
          Participants ({map_size(@game.participants)})
        </p>
        <ul class="space-y-2">
          <%= for {_id, participant} <- @game.participants do %>
            <li class="flex items-center justify-between">
              <div class="flex items-center gap-2">
                <span class={["w-2 h-2 rounded-full", if(participant.connected, do: "bg-success", else: "bg-base-300")]}></span>
                <span class="text-sm">
                  {participant.display_name}
                  <span :if={participant.is_host} class="text-xs text-primary ml-1">(host)</span>
                  <span :if={participant.id == @participant_id} class="text-xs text-base-content/50 ml-1">(you)</span>
                </span>
              </div>
              <button
                :if={@is_host && !participant.is_host}
                type="button"
                class="btn btn-ghost btn-xs text-error"
                phx-click="kick"
                phx-value-id={participant.id}
                aria-label={"Kick #{participant.display_name}"}
              >
                Remove
              </button>
            </li>
          <% end %>
        </ul>
      </div>
    </div>
    """
  end

  # ------------------- EVENTS -------------------

  @impl true
  def handle_event("update_join_name", %{"value" => value}, socket) do
    {:noreply, assign(socket, join_name: value, join_error: nil)}
  end

  def handle_event("join", _params, socket) do
    name = String.trim(socket.assigns.join_name)

    if name == "" do
      {:noreply, assign(socket, join_error: "Please enter a display name")}
    else
      id = socket.assigns.bracket_id

      case Bracket.BracketServer.join(id, name, self()) do
        {:ok, participant_id} ->
          # put_session/3 is not available in handle_event.
          # Sign the credentials with Phoenix.Token (expires in 30s) so the
          # participant_id never appears raw in the URL, preventing session
          # hijacking via crafted URLs.
          signed =
            Phoenix.Token.sign(socket, "participant_session", %{
              "id" => id,
              "participant_id" => participant_id
            })

          {:noreply,
           socket
           |> redirect(to: ~p"/session/participant?session_token=#{signed}")}

        {:error, reason} ->
          {:noreply, assign(socket, join_error: format_join_error(reason))}
      end
    end
  end

  def handle_event("vote", %{"choice" => choice, "matchup_id" => matchup_id_str}, socket)
      when choice in ["a", "b"] do
    matchup_id = parse_matchup_id(matchup_id_str)

    Bracket.BracketServer.vote(
      socket.assigns.bracket_id,
      socket.assigns.participant_id,
      matchup_id,
      String.to_existing_atom(choice)
    )

    {:noreply, assign(socket, my_vote: choice)}
  end

  def handle_event("vote", _params, socket), do: {:noreply, socket}

  def handle_event("start", _params, %{assigns: %{is_host: true}} = socket) do
    case Bracket.BracketServer.start_bracket(socket.assigns.bracket_id, socket.assigns.host_token) do
      :ok -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Could not start: #{reason}")}
    end
  end

  def handle_event("start", _params, socket), do: {:noreply, socket}

  def handle_event("close_matchup", _params, %{assigns: %{is_host: true}} = socket) do
    case Bracket.BracketServer.close_matchup(socket.assigns.bracket_id, socket.assigns.host_token) do
      :ok -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Could not close matchup: #{reason}")}
    end
  end

  def handle_event("close_matchup", _params, socket), do: {:noreply, socket}

  def handle_event("kick", %{"id" => participant_id}, %{assigns: %{is_host: true}} = socket) do
    case Bracket.BracketServer.kick(
           socket.assigns.bracket_id,
           socket.assigns.host_token,
           participant_id
         ) do
      :ok -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Could not kick: #{reason}")}
    end
  end

  def handle_event("kick", _params, socket), do: {:noreply, socket}

  def handle_event("restart", _params, %{assigns: %{is_host: true}} = socket) do
    case Bracket.BracketServer.restart(socket.assigns.bracket_id, socket.assigns.host_token) do
      :ok -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Could not restart: #{reason}")}
    end
  end

  def handle_event("restart", _params, socket), do: {:noreply, socket}

  def handle_event("set_timer", %{"value" => seconds_str}, %{assigns: %{is_host: true}} = socket) do
    case Integer.parse(seconds_str) do
      {seconds, _} ->
        case Bracket.BracketServer.set_timer(socket.assigns.bracket_id, socket.assigns.host_token, seconds) do
          :ok -> {:noreply, socket}
          {:error, reason} -> {:noreply, put_flash(socket, :error, "Could not set timer: #{reason}")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("set_timer", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_timer", _params, %{assigns: %{is_host: true}} = socket) do
    new_timer =
      if socket.assigns.game.timer_seconds != nil do
        nil
      else
        60
      end

    case Bracket.BracketServer.set_timer(socket.assigns.bracket_id, socket.assigns.host_token, new_timer) do
      :ok -> {:noreply, socket}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_event("toggle_timer", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_bracket_panel", _params, socket) do
    {:noreply, assign(socket, show_bracket_panel: !socket.assigns.show_bracket_panel)}
  end

  def handle_event("reconnected", _params, socket) do
    {:noreply, assign(socket, phase: determine_phase(socket.assigns.game, socket.assigns.participant_id, socket.assigns.host_token))}
  end

  # ------------------- PUBSUB MESSAGES -------------------

  @impl true
  def handle_info({:bracket_event, :participant_joined, game}, socket) do
    {:noreply, update_game(socket, game)}
  end

  def handle_info({:bracket_event, :participant_left, game}, socket) do
    {:noreply, update_game(socket, game)}
  end

  def handle_info({:bracket_event, :bracket_started, game}, socket) do
    socket = update_game(socket, game)
    {:noreply, assign(socket, my_vote: nil)}
  end

  def handle_info({:bracket_event, :matchup_closed, game}, socket) do
    socket = update_game(socket, game)
    {:noreply, assign(socket, my_vote: nil)}
  end

  def handle_info({:bracket_event, :round_complete, game}, socket) do
    socket = update_game(socket, game)
    {:noreply, assign(socket, my_vote: nil)}
  end

  def handle_info({:bracket_event, :bracket_champion, game}, socket) do
    {:noreply, update_game(socket, game)}
  end

  def handle_info({:bracket_event, :bracket_restarted, game}, socket) do
    socket = update_game(socket, game)
    {:noreply, assign(socket, my_vote: nil)}
  end

  def handle_info({:bracket_event, :kicked, kicked_participant_id}, socket) do
    if kicked_participant_id == socket.assigns.participant_id do
      {:noreply, assign(socket, phase: :kicked)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:bracket_event, :host_transferred, new_host_id, new_host_token, game}, socket) do
    # Note: put_session is not available here. The new host_token is stored in
    # assigns only for the lifetime of this LiveView session. If the page is
    # refreshed, the new host can use the host recovery URL that will be shown
    # in the UI with the updated token.
    socket =
      if new_host_id == socket.assigns.participant_id do
        assign(socket, is_host: true, host_token: new_host_token)
      else
        socket
      end

    {:noreply, update_game(socket, game)}
  end

  def handle_info({:vote_update, matchup_id, count_a, count_b, total_eligible}, socket) do
    game = socket.assigns.game

    if game == nil do
      {:noreply, socket}
    else
      current_round_idx = game.current_round

      updated_rounds =
        game.rounds
        |> Enum.with_index()
        |> Enum.map(fn {round, idx} ->
          if idx == current_round_idx do
            updated_matchups =
              Enum.map(round.matchups, fn matchup ->
                if matchup.id == matchup_id do
                  %{matchup | votes: %{count_a: count_a, count_b: count_b, total_eligible: total_eligible}}
                else
                  matchup
                end
              end)

            %{round | matchups: updated_matchups}
          else
            round
          end
        end)

      {:noreply, assign(socket, game: %{game | rounds: updated_rounds})}
    end
  end

  # ------------------- HELPERS -------------------

  defp update_game(socket, game) do
    phase = determine_phase(game, socket.assigns.participant_id, socket.assigns.host_token)
    assign(socket, game: game, phase: phase, page_title: game.name)
  end

  defp determine_phase(game, participant_id, host_token) do
    case game.status do
      :finished ->
        :finished

      _ ->
        if participant_id == nil && host_token == nil do
          :join_form
        else
          case game.status do
            :lobby ->
              :lobby

            :active ->
              participant = Map.get(game.participants, participant_id)

              if participant == nil do
                :join_form
              else
                eligible_from = participant.eligible_from_matchup

                if eligible_from == nil || eligible_from <= game.current_matchup do
                  :voting
                else
                  :waiting
                end
              end

            :finished ->
              :finished
          end
        end
    end
  end

  defp current_matchup(%{rounds: rounds, current_round: round_idx, current_matchup: matchup_idx}) do
    case Enum.at(rounds, round_idx) do
      nil -> nil
      round -> Enum.find(round.matchups, fn m -> m.id == matchup_idx end)
    end
  end

  defp current_matchup(_), do: nil

  defp vote_count(%{votes: %{count_a: a, count_b: b}}), do: a + b
  defp vote_count(_), do: 0

  defp eligible_count(%{votes: %{total_eligible: n}}), do: n
  defp eligible_count(_), do: 0

  defp voted_for?(my_vote, choice), do: my_vote == choice

  defp bracket_url(id) do
    BracketWeb.Endpoint.url() <> ~p"/bracket/#{id}"
  end

  defp host_recovery_url(id, host_token) when is_binary(host_token) do
    BracketWeb.Endpoint.url() <> ~p"/bracket/#{id}/host?token=#{host_token}"
  end

  defp host_recovery_url(_, _), do: ""

  defp format_join_error(:bracket_finished), do: "This bracket has already finished."
  defp format_join_error(:bracket_full), do: "This bracket is full (max 50 participants)."
  defp format_join_error(_), do: "Could not join. Please try again."

  defp parse_matchup_id(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> str
    end
  end

  defp parse_matchup_id(id), do: id
end
