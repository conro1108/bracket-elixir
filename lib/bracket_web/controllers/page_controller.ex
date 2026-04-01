defmodule BracketWeb.PageController do
  use BracketWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
