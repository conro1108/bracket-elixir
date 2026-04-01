defmodule BracketWeb.PageControllerTest do
  use BracketWeb.ConnCase

  test "GET / redirects to HomeLive", %{conn: conn} do
    # GET / now serves a LiveView, which returns 200 on initial render
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Bracket"
  end
end
