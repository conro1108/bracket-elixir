defmodule Bracket.BracketServerTest do
  use ExUnit.Case, async: false

  alias Bracket.BracketServer

  import BracketFactory

  setup do
    # Each test gets a fresh bracket process
    {:ok, id, host_token} = create_bracket_server()
    %{id: id, host_token: host_token}
  end

  # ---------------------------------------------------------------------------
  # 2.1 Process Lifecycle
  # ---------------------------------------------------------------------------

  describe "create/1" do
    @tag :smoke
    test "creates and registers a GenServer" do
      {:ok, id, _token} = create_bracket_server()
      assert [{_pid, _}] = Registry.lookup(Bracket.Registry, id)
    end

    test "returns {:ok, id, host_token}" do
      result = BracketServer.create(%{name: "T", items: ["A", "B", "C", "D"], host_name: "H"})
      assert {:ok, id, token} = result
      assert is_binary(id)
      assert is_binary(token)
    end

    test "returns error for too few items" do
      assert {:error, :too_few_items} =
               BracketServer.create(%{name: "T", items: ["A", "B"], host_name: "H"})
    end
  end

  describe "get_state/1" do
    test "returns sanitized public state", %{id: id} do
      {:ok, game} = BracketServer.get_state(id)
      assert game.status == :lobby
      assert game.host_token == nil
    end

    test "returns {:error, :not_found} for unknown id" do
      assert {:error, :not_found} = BracketServer.get_state("nonexistent")
    end
  end

  # ---------------------------------------------------------------------------
  # 2.2 Join Flow
  # ---------------------------------------------------------------------------

  describe "join/3" do
    @tag :smoke
    test "returns {:ok, participant_id}", %{id: id} do
      assert {:ok, pid} = BracketServer.join(id, "Alice", nil)
      assert is_binary(pid)
    end

    test "broadcasts :participant_joined via PubSub", %{id: id} do
      Phoenix.PubSub.subscribe(Bracket.PubSub, "bracket:#{id}")
      BracketServer.join(id, "Alice", nil)
      assert_receive {:bracket_event, :participant_joined, _game}, 500
    end

    test "updates participant list in state", %{id: id} do
      {:ok, _} = BracketServer.join(id, "Alice", nil)
      {:ok, game} = BracketServer.get_state(id)
      names = Enum.map(Map.values(game.participants), & &1.display_name)
      assert "Alice" in names
    end
  end

  # ---------------------------------------------------------------------------
  # 2.3 Voting Flow
  # ---------------------------------------------------------------------------

  describe "vote/4 and auto-close" do
    setup %{id: id, host_token: host_token} do
      {:ok, p2_id} = BracketServer.join(id, "Player2", nil)
      :ok = BracketServer.start_bracket(id, host_token)
      {:ok, game} = BracketServer.get_state(id)
      %{p2_id: p2_id, matchup_id: game.current_matchup}
    end

    @tag :smoke
    test "broadcasting vote_update after voting", %{id: id, host_token: host_token, matchup_id: matchup_id} do
      Phoenix.PubSub.subscribe(Bracket.PubSub, "bracket:#{id}")

      {:ok, game} = BracketServer.get_state(id)
      host_participant_id = Enum.find_value(game.participants, fn {k, p} -> p.is_host && k end)

      BracketServer.vote(id, host_participant_id, matchup_id, :a)
      assert_receive {:vote_update, ^matchup_id, _, _, _}, 500
    end

    test "auto-closes matchup when all eligible voted", %{id: id, host_token: host_token, p2_id: p2_id, matchup_id: matchup_id} do
      Phoenix.PubSub.subscribe(Bracket.PubSub, "bracket:#{id}")
      {:ok, game} = BracketServer.get_state(id)
      host_id = Enum.find_value(game.participants, fn {k, p} -> p.is_host && k end)

      BracketServer.vote(id, host_id, matchup_id, :a)
      BracketServer.vote(id, p2_id, matchup_id, :a)

      # Should receive matchup_closed or round_complete
      assert_receive {:bracket_event, event, _game}, 1000
      assert event in [:matchup_closed, :round_complete, :bracket_champion]
    end
  end

  # ---------------------------------------------------------------------------
  # 2.4 Host Actions
  # ---------------------------------------------------------------------------

  describe "start_bracket/2" do
    @tag :smoke
    test "transitions to active and broadcasts", %{id: id, host_token: host_token} do
      Phoenix.PubSub.subscribe(Bracket.PubSub, "bracket:#{id}")
      :ok = BracketServer.start_bracket(id, host_token)
      assert_receive {:bracket_event, :bracket_started, game}, 500
      assert game.status == :active
    end

    test "rejects with wrong token", %{id: id} do
      assert {:error, :unauthorized} = BracketServer.start_bracket(id, "bad")
    end
  end

  describe "close_matchup/2" do
    setup %{id: id, host_token: host_token} do
      BracketServer.join(id, "P2", nil)
      :ok = BracketServer.start_bracket(id, host_token)
      :ok
    end

    test "closes matchup early and broadcasts", %{id: id, host_token: host_token} do
      Phoenix.PubSub.subscribe(Bracket.PubSub, "bracket:#{id}")
      :ok = BracketServer.close_matchup(id, host_token)
      assert_receive {:bracket_event, event, _}, 500
      assert event in [:matchup_closed, :round_complete, :bracket_champion]
    end

    test "rejects with wrong token", %{id: id} do
      assert {:error, :unauthorized} = BracketServer.close_matchup(id, "bad")
    end
  end

  describe "kick/3" do
    test "removes participant and broadcasts kicked", %{id: id, host_token: host_token} do
      {:ok, p2_id} = BracketServer.join(id, "Alice", nil)
      Phoenix.PubSub.subscribe(Bracket.PubSub, "bracket:#{id}")
      :ok = BracketServer.kick(id, host_token, p2_id)
      assert_receive {:bracket_event, :kicked, ^p2_id}, 500
    end

    test "rejects with wrong token", %{id: id} do
      {:ok, p2_id} = BracketServer.join(id, "Alice", nil)
      assert {:error, :unauthorized} = BracketServer.kick(id, "bad", p2_id)
    end
  end

  describe "restart/2" do
    setup %{id: id, host_token: host_token} do
      BracketServer.join(id, "P2", nil)
      :ok = BracketServer.start_bracket(id, host_token)
      :ok
    end

    test "resets bracket to lobby and broadcasts", %{id: id, host_token: host_token} do
      Phoenix.PubSub.subscribe(Bracket.PubSub, "bracket:#{id}")
      :ok = BracketServer.restart(id, host_token)
      assert_receive {:bracket_event, :bracket_restarted, game}, 500
      assert game.status == :lobby
    end
  end

  # ---------------------------------------------------------------------------
  # 2.7 Cleanup / Inactivity
  # ---------------------------------------------------------------------------

  describe "cleanup" do
    @tag :slow
    test "GenServer terminates after inactivity threshold" do
      {:ok, id, _} = create_bracket_server()
      [{pid, _}] = Registry.lookup(Bracket.Registry, id)
      ref = Process.monitor(pid)

      # The test config sets cleanup_inactive_threshold to 200ms and
      # cleanup_interval to 100ms, so the process should stop within ~300ms
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    end
  end

  # ---------------------------------------------------------------------------
  # 2.8 Full Game Walkthrough
  # ---------------------------------------------------------------------------

  describe "full game walkthrough" do
    @tag :smoke
    test "4-item bracket plays to champion through GenServer" do
      {id, host_token, [p2_id]} = advance_to_voting(1)
      {:ok, game} = BracketServer.get_state(id)
      host_id = Enum.find_value(game.participants, fn {k, p} -> p.is_host && k end)

      Phoenix.PubSub.subscribe(Bracket.PubSub, "bracket:#{id}")

      # Play all matchups (4 items = 3 matchups total: 2 in round 0, 1 in round 1)
      Enum.each(1..3, fn _ ->
        {:ok, game} = BracketServer.get_state(id)
        if game.status == :active do
          BracketServer.vote(id, host_id, game.current_matchup, :a)
          BracketServer.vote(id, p2_id, game.current_matchup, :a)
          Process.sleep(50)
        end
      end)

      # Wait for champion event
      assert_receive {:bracket_event, :bracket_champion, final_game}, 2000
      assert final_game.status == :finished
    end
  end
end
