defmodule BracketWeb.SessionController do
  @moduledoc """
  Handles session cookie writes that LiveView handle_event cannot perform directly.

  After bracket creation, HomeLive redirects here with the bracket ID and
  host_token in query params. This controller validates the token, stores it
  in the signed session, and redirects to the bracket page.

  Similarly handles participant_id storage after joining.
  """
  use BracketWeb, :controller

  def set_host(conn, %{"id" => id, "token" => token}) do
    case Bracket.BracketServer.validate_host_token(id, token) do
      :ok ->
        conn
        |> put_session("host_token", token)
        |> redirect(to: ~p"/bracket/#{id}")

      {:error, :unauthorized} ->
        conn
        |> put_flash(:error, "Invalid host token.")
        |> redirect(to: ~p"/")
    end
  end

  def set_host(conn, _params) do
    conn
    |> put_flash(:error, "Missing parameters.")
    |> redirect(to: ~p"/")
  end

  def set_participant(conn, %{"id" => id, "participant_id" => participant_id}) do
    conn
    |> put_session("participant_id_#{id}", participant_id)
    |> redirect(to: ~p"/bracket/#{id}")
  end

  def set_participant(conn, _params) do
    conn
    |> put_flash(:error, "Missing parameters.")
    |> redirect(to: ~p"/")
  end
end
