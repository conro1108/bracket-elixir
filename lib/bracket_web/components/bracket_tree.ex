defmodule BracketWeb.Components.BracketTree do
  use Phoenix.Component

  attr :game, :map, required: true

  def bracket_tree(assigns) do
    ~H"""
    <div class="bracket-tree overflow-x-auto touch-pan-x overscroll-contain">
      <div class="flex gap-8 p-4" style="min-width: max-content;">
        <%= for {round, round_idx} <- Enum.with_index(@game.rounds) do %>
          <div class="flex flex-col justify-around gap-4 min-w-[160px]">
            <div class="text-xs font-semibold text-base-content/50 uppercase mb-2 tracking-wide">
              {round_label(round_idx, length(@game.rounds))}
            </div>
            <div class="flex flex-col justify-around flex-1 gap-4">
              <%= for matchup <- round.matchups do %>
                <div class={[
                  "bracket-matchup border rounded-lg p-2 text-sm",
                  matchup_classes(matchup, @game)
                ]}>
                  <div class={item_class(matchup, matchup.item_a)}>
                    {matchup.item_a || "BYE"}
                  </div>
                  <div class="border-t border-base-300 my-1"></div>
                  <div class={item_class(matchup, matchup.item_b)}>
                    {matchup.item_b || "BYE"}
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp round_label(idx, total) do
    rounds_from_end = total - 1 - idx

    case rounds_from_end do
      0 -> "Final"
      1 -> "Semifinals"
      2 -> "Quarterfinals"
      _ -> "Round #{idx + 1}"
    end
  end

  defp matchup_classes(matchup, game) do
    current_round = Map.get(game, :current_round, 0)
    current_matchup_idx = Map.get(game, :current_matchup, 0)

    # Find which round this matchup belongs to
    round_idx =
      Enum.find_index(game.rounds, fn r ->
        Enum.any?(r.matchups, fn m -> m.id == matchup.id end)
      end)

    is_current =
      round_idx == current_round and matchup.id == current_matchup_idx and
        matchup.status == :active

    cond do
      is_current ->
        "border-primary bg-primary/10 shadow-md"

      matchup.status == :closed ->
        "border-base-300 bg-base-200/50 opacity-80"

      matchup.status == :pending ->
        "border-base-300 bg-base-100 opacity-50"

      true ->
        "border-base-300 bg-base-100"
    end
  end

  defp item_class(matchup, item) do
    base = "px-1 py-0.5 rounded text-sm truncate"

    cond do
      matchup.status != :closed ->
        base

      matchup.winner == item ->
        base <> " font-bold text-success"

      item == nil ->
        base <> " text-base-content/30 italic"

      true ->
        base <> " text-base-content/40 line-through"
    end
  end
end
