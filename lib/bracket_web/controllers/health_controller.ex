defmodule BracketWeb.HealthController do
  use BracketWeb, :controller

  @start_time System.monotonic_time(:second)

  def index(conn, _params) do
    bracket_count =
      case DynamicSupervisor.count_children(Bracket.DynamicSupervisor) do
        %{active: active} -> active
        _ -> 0
      end

    uptime_seconds = System.monotonic_time(:second) - @start_time

    json(conn, %{
      status: "ok",
      bracket_count: bracket_count,
      uptime_seconds: uptime_seconds
    })
  end
end
