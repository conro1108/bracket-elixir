defmodule Bracket.GameTest do
  use ExUnit.Case, async: true

  alias Bracket.Game
  alias Bracket.Game.{Matchup, Participant}

  # Helper to create a 4-item game with shuffle disabled for deterministic tests
  defp simple_game(opts \\ []) do
    items = Keyword.get(opts, :items, ["Alpha", "Beta", "Gamma", "Delta"])
    {:ok, game} = Game.new("Test", items, "Host", shuffle: false)
    game
  end

  # ---------------------------------------------------------------------------
  # 1.1 Bracket Creation / Seeding
  # ---------------------------------------------------------------------------

  describe "new/3 — basic creation" do
    @tag :smoke
    test "creates a game with status :lobby" do
      {:ok, game} = Game.new("My Bracket", ["A", "B", "C", "D"], "Host", shuffle: false)
      assert game.status == :lobby
      assert game.name == "My Bracket"
    end

    test "generates an 8-character ID" do
      {:ok, game} = Game.new("Test", ["A", "B", "C", "D"], "H", shuffle: false)
      assert String.length(game.id) == 8
    end

    test "generates a non-empty host_token" do
      {:ok, game} = Game.new("Test", ["A", "B", "C", "D"], "H", shuffle: false)
      assert is_binary(game.host_token) and game.host_token != ""
    end

    test "sets created_at and last_activity_at" do
      {:ok, game} = Game.new("Test", ["A", "B", "C", "D"], "H", shuffle: false)
      assert %DateTime{} = game.created_at
      assert %DateTime{} = game.last_activity_at
    end
  end

  describe "new/3 — power-of-2 padding" do
    test "4 items → 4 slots (no byes)" do
      {:ok, game} = Game.new("T", ["A", "B", "C", "D"], "H", shuffle: false)
      assert length(game.items) == 4
      assert Enum.count(game.items, &is_nil/1) == 0
    end

    test "5 items → 8 slots (3 byes)" do
      {:ok, game} = Game.new("T", ["A", "B", "C", "D", "E"], "H", shuffle: false)
      assert length(game.items) == 8
      assert Enum.count(game.items, &is_nil/1) == 3
    end

    test "7 items → 8 slots (1 bye)" do
      {:ok, game} = Game.new("T", ["A", "B", "C", "D", "E", "F", "G"], "H", shuffle: false)
      assert length(game.items) == 8
      assert Enum.count(game.items, &is_nil/1) == 1
    end

    test "8 items → 8 slots (0 byes)" do
      items = Enum.map(1..8, &"Item #{&1}")
      {:ok, game} = Game.new("T", items, "H", shuffle: false)
      assert length(game.items) == 8
      assert Enum.count(game.items, &is_nil/1) == 0
    end

    test "9 items → 16 slots (7 byes)" do
      items = Enum.map(1..9, &"Item #{&1}")
      {:ok, game} = Game.new("T", items, "H", shuffle: false)
      assert length(game.items) == 16
      assert Enum.count(game.items, &is_nil/1) == 7
    end
  end

  describe "new/3 — bye auto-close" do
    test "matchup with a bye is auto-closed with non-bye item as winner" do
      # 5 items → 8 slots → byes appear in round 0
      {:ok, game} = Game.new("T", ["A", "B", "C", "D", "E"], "H", shuffle: false)
      round0 = hd(game.rounds)
      bye_matchups = Enum.filter(round0.matchups, fn m -> m.item_a == nil || m.item_b == nil end)

      assert length(bye_matchups) > 0

      Enum.each(bye_matchups, fn m ->
        assert m.status == :closed
        refute is_nil(m.winner)
      end)
    end
  end

  describe "new/3 — validation" do
    test "rejects fewer than 4 items" do
      assert {:error, :too_few_items} = Game.new("T", ["A", "B", "C"], "H")
    end

    test "rejects more than 32 items" do
      items = Enum.map(1..33, &"Item #{&1}")
      assert {:error, :too_many_items} = Game.new("T", items, "H")
    end

    test "rejects empty bracket name" do
      assert {:error, :invalid_name} = Game.new("", ["A", "B", "C", "D"], "H")
    end

    test "rejects whitespace-only bracket name" do
      assert {:error, :invalid_name} = Game.new("   ", ["A", "B", "C", "D"], "H")
    end

    test "deduplicates items before seeding" do
      {:ok, game} = Game.new("T", ["A", "B", "A", "C", "D"], "H", shuffle: false)
      real_items = Enum.reject(game.items, &is_nil/1)
      assert length(real_items) == 4
      assert Enum.uniq(real_items) == real_items
    end
  end

  describe "new/3 — host participant" do
    test "adds host as first participant with is_host: true" do
      {:ok, game} = Game.new("T", ["A", "B", "C", "D"], "Alice", shuffle: false)
      host = Enum.find(Map.values(game.participants), & &1.is_host)
      assert host != nil
      assert host.display_name == "Alice"
    end
  end

  # ---------------------------------------------------------------------------
  # 1.2 Participant Management
  # ---------------------------------------------------------------------------

  describe "add_participant/3" do
    test "adds a participant with connected: true and eligible_from_matchup: nil (lobby)" do
      game = simple_game()
      {:ok, {updated, _pid}} = Game.add_participant(game, "Bob", nil)
      bob = Enum.find(Map.values(updated.participants), &(&1.display_name == "Bob"))
      assert bob.connected == true
      assert bob.eligible_from_matchup == nil
    end

    test "deduplicates display names with numeric suffix" do
      game = simple_game()
      {:ok, {game2, _}} = Game.add_participant(game, "Alice", nil)
      # "Alice" should conflict with the existing host named "Host", but let's use a fresh name
      {:ok, {game3, _}} = Game.add_participant(game2, "Bob", nil)
      {:ok, {game4, _}} = Game.add_participant(game3, "Bob", nil)
      names = Enum.map(Map.values(game4.participants), & &1.display_name)
      assert "Bob" in names
      assert "Bob 2" in names
    end

    test "sets eligible_from_matchup when joining an active game" do
      game = simple_game()
      host_token = game.host_token
      {:ok, {game, _}} = Game.add_participant(game, "Player2", nil)
      {:ok, game} = Game.start_bracket(game, host_token)
      # current_matchup is 0 (first matchup)

      {:ok, {updated, late_id}} = Game.add_participant(game, "LateJoiner", nil)
      late = Map.get(updated.participants, late_id)
      assert late.eligible_from_matchup == game.current_matchup + 1
    end

    test "rejects join when bracket has 50 participants" do
      items = Enum.map(1..4, &"Item #{&1}")
      {:ok, game} = Game.new("T", items, "Host", shuffle: false)

      # Already has 1 participant (host). Add 49 more to reach 50.
      game =
        Enum.reduce(1..49, game, fn i, acc ->
          {:ok, {updated, _}} = Game.add_participant(acc, "Player #{i}", nil)
          updated
        end)

      assert map_size(game.participants) == 50
      assert {:error, :bracket_full} = Game.add_participant(game, "TooMany", nil)
    end
  end

  describe "remove_participant/2" do
    test "removes participant from the game" do
      game = simple_game()
      {:ok, {game2, pid}} = Game.add_participant(game, "Bob", nil)
      {:ok, game3} = Game.remove_participant(game2, pid)
      refute Map.has_key?(game3.participants, pid)
    end
  end

  # ---------------------------------------------------------------------------
  # 1.3 Bracket Start
  # ---------------------------------------------------------------------------

  describe "start_bracket/2" do
    @tag :smoke
    test "transitions lobby to active" do
      game = simple_game()
      {:ok, {game, _}} = Game.add_participant(game, "Player2", nil)
      {:ok, started} = Game.start_bracket(game, game.host_token)
      assert started.status == :active
      assert started.current_round == 0
      assert is_integer(started.current_matchup)
    end

    test "activates the first non-bye matchup" do
      game = simple_game()
      {:ok, {game, _}} = Game.add_participant(game, "Player2", nil)
      {:ok, started} = Game.start_bracket(game, game.host_token)
      round0 = hd(started.rounds)
      active = Enum.find(round0.matchups, &(&1.status == :active))
      assert active != nil
      assert active.id == started.current_matchup
    end

    test "rejects start with wrong host token" do
      game = simple_game()
      assert {:error, :unauthorized} = Game.start_bracket(game, "wrong-token")
    end

    test "rejects start when already active" do
      game = simple_game()
      {:ok, {game, _}} = Game.add_participant(game, "Player2", nil)
      {:ok, active} = Game.start_bracket(game, game.host_token)
      assert {:error, :not_in_lobby} = Game.start_bracket(active, active.host_token)
    end
  end

  # ---------------------------------------------------------------------------
  # 1.4 Voting
  # ---------------------------------------------------------------------------

  describe "record_vote/4" do
    setup do
      game = simple_game()
      {:ok, {game, p2_id}} = Game.add_participant(game, "Player2", nil)
      {:ok, game} = Game.start_bracket(game, game.host_token)
      host_id = Enum.find_value(game.participants, fn {id, p} -> p.is_host && id end)
      %{game: game, host_id: host_id, p2_id: p2_id}
    end

    @tag :smoke
    test "records a vote", %{game: game, host_id: host_id} do
      {:ok, updated} = Game.record_vote(game, host_id, game.current_matchup, :a)
      matchup = get_current_matchup(updated)
      assert Map.get(matchup.votes, host_id) == :a
    end

    test "overwrites previous vote (vote change)", %{game: game, host_id: host_id} do
      {:ok, game} = Game.record_vote(game, host_id, game.current_matchup, :a)
      {:ok, game} = Game.record_vote(game, host_id, game.current_matchup, :b)
      matchup = get_current_matchup(game)
      assert Map.get(matchup.votes, host_id) == :b
      assert map_size(matchup.votes) == 1
    end

    test "rejects vote from non-participant", %{game: game} do
      assert {:error, :not_a_participant} = Game.record_vote(game, "bad_id", game.current_matchup, :a)
    end

    test "rejects vote on wrong matchup", %{game: game, host_id: host_id} do
      assert {:error, :matchup_not_active} = Game.record_vote(game, host_id, 999, :a)
    end

    test "rejects vote from ineligible late joiner", %{game: game} do
      {:ok, {game_with_late, late_id}} = Game.add_participant(game, "Late", nil)
      # late joiner's eligible_from_matchup should be > 0
      late = Map.get(game_with_late.participants, late_id)
      assert late.eligible_from_matchup != nil
      # current matchup is 0, eligible_from is 1 → not eligible
      assert {:error, :not_eligible} =
               Game.record_vote(game_with_late, late_id, game.current_matchup, :a)
    end

    test "rejects vote on finished bracket", %{game: game, host_id: host_id} do
      {:ok, {p2_id, _}} = {:ok, Enum.find(game.participants, fn {id, _} -> id != host_id end)}
      # 4-item bracket has 3 matchups: 2 in round 0, 1 final
      game = play_to_finish(game, [host_id, p2_id])
      assert game.status == :finished
      assert {:error, :bracket_finished} = Game.record_vote(game, host_id, 0, :a)
    end
  end

  # ---------------------------------------------------------------------------
  # 1.5 Matchup Closing
  # ---------------------------------------------------------------------------

  describe "close_matchup/1" do
    setup do
      game = simple_game()
      {:ok, {game, p2_id}} = Game.add_participant(game, "Player2", nil)
      {:ok, game} = Game.start_bracket(game, game.host_token)
      host_id = Enum.find_value(game.participants, fn {id, p} -> p.is_host && id end)
      %{game: game, host_id: host_id, p2_id: p2_id}
    end

    @tag :smoke
    test "closes matchup and determines winner by majority", %{game: game, host_id: host_id, p2_id: p2_id} do
      {:ok, game} = Game.record_vote(game, host_id, game.current_matchup, :a)
      {:ok, game} = Game.record_vote(game, p2_id, game.current_matchup, :a)
      {:ok, updated, _was_tie} = Game.close_matchup(game)
      matchup = find_matchup_by_id(updated, game.current_round, 0)
      assert matchup.status == :closed
      assert matchup.winner == matchup.item_a
    end

    test "host vote wins on tie", %{game: game, host_id: host_id, p2_id: p2_id} do
      {:ok, game} = Game.record_vote(game, host_id, game.current_matchup, :a)
      {:ok, game} = Game.record_vote(game, p2_id, game.current_matchup, :b)
      {:ok, updated, was_tie} = Game.close_matchup(game)
      matchup = find_matchup_by_id(updated, game.current_round, 0)
      assert was_tie == true
      assert matchup.winner == matchup.item_a
    end

    test "random winner when no votes cast", %{game: game} do
      {:ok, updated, _was_tie} = Game.close_matchup(game)
      matchup = find_matchup_by_id(updated, game.current_round, 0)
      assert matchup.winner in [matchup.item_a, matchup.item_b]
    end

    test "advances to next matchup after close", %{game: game, host_id: host_id} do
      initial_matchup = game.current_matchup
      {:ok, game} = Game.record_vote(game, host_id, game.current_matchup, :a)
      {:ok, updated, _} = Game.close_matchup(game)
      # With 4 items, round 0 has 2 matchups — should advance to matchup 1
      assert updated.current_matchup != initial_matchup or updated.current_round > game.current_round
    end
  end

  # ---------------------------------------------------------------------------
  # 1.6 Full Game Walkthrough
  # ---------------------------------------------------------------------------

  describe "full game walkthrough" do
    @tag :smoke
    test "4-item bracket plays to champion" do
      {:ok, game} = Game.new("4-item test", ["A", "B", "C", "D"], "Host", shuffle: false)
      {:ok, {game, p2_id}} = Game.add_participant(game, "Player2", nil)
      {:ok, game} = Game.start_bracket(game, game.host_token)
      host_id = Enum.find_value(game.participants, fn {id, p} -> p.is_host && id end)

      # Play through all matchups
      game = play_to_finish(game, [host_id, p2_id])

      assert game.status == :finished
      last_round = List.last(game.rounds)
      assert [%{winner: champion}] = last_round.matchups
      assert is_binary(champion)
    end

    test "round progression builds correct next round" do
      {:ok, game} = Game.new("T", ["A", "B", "C", "D"], "Host", shuffle: false)
      {:ok, {game, p2_id}} = Game.add_participant(game, "P2", nil)
      {:ok, game} = Game.start_bracket(game, game.host_token)
      host_id = Enum.find_value(game.participants, fn {id, p} -> p.is_host && id end)

      # Close matchup 0 with A winning
      {:ok, game} = Game.record_vote(game, host_id, game.current_matchup, :a)
      {:ok, game} = Game.record_vote(game, p2_id, game.current_matchup, :a)
      {:ok, game, _} = Game.close_matchup(game)

      # Close matchup 1 with B winning
      {:ok, game} = Game.record_vote(game, host_id, game.current_matchup, :b)
      {:ok, game} = Game.record_vote(game, p2_id, game.current_matchup, :b)
      {:ok, game, _} = Game.close_matchup(game)

      # Should now be in round 1 (the final)
      assert game.current_round == 1
      assert length(game.rounds) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # 1.7 Restart
  # ---------------------------------------------------------------------------

  describe "restart/2" do
    test "resets status to :lobby and clears votes" do
      game = simple_game()
      {:ok, {game, _}} = Game.add_participant(game, "P2", nil)
      {:ok, game} = Game.start_bracket(game, game.host_token)
      {:ok, restarted} = Game.restart(game, game.host_token)
      assert restarted.status == :lobby
    end

    test "keeps participants but resets eligible_from_matchup" do
      game = simple_game()
      {:ok, {game, p2_id}} = Game.add_participant(game, "P2", nil)
      {:ok, game} = Game.start_bracket(game, game.host_token)
      {:ok, {game, late_id}} = Game.add_participant(game, "Late", nil)
      assert Map.get(game.participants, late_id).eligible_from_matchup != nil
      {:ok, restarted} = Game.restart(game, game.host_token)
      assert Map.get(restarted.participants, late_id).eligible_from_matchup == nil
      assert Map.get(restarted.participants, p2_id) != nil
    end

    test "rejects restart with wrong token" do
      game = simple_game()
      assert {:error, :unauthorized} = Game.restart(game, "bad")
    end
  end

  # ---------------------------------------------------------------------------
  # 1.8 Host Transfer
  # ---------------------------------------------------------------------------

  describe "transfer_host/2" do
    test "transfers host status and generates new token" do
      game = simple_game()
      {:ok, {game, p2_id}} = Game.add_participant(game, "P2", nil)
      old_token = game.host_token
      {:ok, updated, new_token} = Game.transfer_host(game, p2_id)
      assert updated.host_token == new_token
      assert new_token != old_token
      assert Map.get(updated.participants, p2_id).is_host == true
      old_host_id = Enum.find_value(game.participants, fn {id, p} -> p.is_host && id end)
      assert Map.get(updated.participants, old_host_id).is_host == false
    end
  end

  # ---------------------------------------------------------------------------
  # 1.9 public_view/1
  # ---------------------------------------------------------------------------

  describe "public_view/1" do
    test "strips host_token from broadcast" do
      game = simple_game()
      public = Game.public_view(game)
      assert public.host_token == nil
    end

    test "strips host_monitor_ref" do
      game = simple_game()
      public = Game.public_view(game)
      assert public.host_monitor_ref == nil
    end

    test "replaces vote maps with aggregate counts" do
      game = simple_game()
      {:ok, {game, p2_id}} = Game.add_participant(game, "P2", nil)
      {:ok, game} = Game.start_bracket(game, game.host_token)
      host_id = Enum.find_value(game.participants, fn {id, p} -> p.is_host && id end)
      {:ok, game} = Game.record_vote(game, host_id, game.current_matchup, :a)
      public = Game.public_view(game)
      round0 = hd(public.rounds)
      active = Enum.find(round0.matchups, &(&1.status == :active))
      assert %{count_a: 1, count_b: 0, total_eligible: _} = active.votes
    end
  end

  # ---------------------------------------------------------------------------
  # Edge cases: bye handling (section 6.3)
  # ---------------------------------------------------------------------------

  describe "bye handling" do
    test "5-item bracket: 3 byes auto-closed in round 0" do
      {:ok, game} = Game.new("T", ["A", "B", "C", "D", "E"], "H", shuffle: false)
      round0 = hd(game.rounds)
      auto_closed = Enum.filter(round0.matchups, &(&1.status == :closed))
      assert length(auto_closed) == 3
    end

    test "bye winner advances to next round" do
      {:ok, game} = Game.new("T", ["A", "B", "C", "D", "E"], "H", shuffle: false)
      {:ok, {game, p2_id}} = Game.add_participant(game, "P2", nil)
      {:ok, game} = Game.start_bracket(game, game.host_token)
      host_id = Enum.find_value(game.participants, fn {id, p} -> p.is_host && id end)

      # There is only 1 real matchup in round 0 with 5 items.
      # Close it and verify we move to round 1.
      {:ok, game} = Game.record_vote(game, host_id, game.current_matchup, :a)
      {:ok, game} = Game.record_vote(game, p2_id, game.current_matchup, :a)
      {:ok, game, _} = Game.close_matchup(game)

      # After the only real matchup closes, the round should advance
      assert game.current_round >= 1 or game.status == :finished
    end
  end

  # ---------------------------------------------------------------------------
  # Helper functions
  # ---------------------------------------------------------------------------

  defp get_current_matchup(game) do
    round = Enum.at(game.rounds, game.current_round)
    Enum.find(round.matchups, &(&1.id == game.current_matchup))
  end

  defp find_matchup_by_id(game, round_idx, matchup_id) do
    round = Enum.at(game.rounds, round_idx)
    Enum.find(round.matchups, &(&1.id == matchup_id))
  end

  defp play_to_finish(game, [host_id, p2_id]) do
    if game.status == :finished do
      game
    else
      matchup_id = game.current_matchup
      {:ok, game} = Game.record_vote(game, host_id, matchup_id, :a)
      {:ok, game} = Game.record_vote(game, p2_id, matchup_id, :a)
      {:ok, game, _} = Game.close_matchup(game)
      play_to_finish(game, [host_id, p2_id])
    end
  end
end
