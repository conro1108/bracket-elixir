defmodule BracketWeb.SessionController do
  @moduledoc """
  Handles session cookie writes that LiveView handle_event cannot perform directly.

  LiveView redirects here with a short-lived Phoenix.Token (not the raw secret)
  in the query string. This controller verifies the token, extracts the payload,
  stores it in the signed session cookie, and redirects to the bracket page.

  Using Phoenix.Token means the actual host_token and participant_id are never
  exposed in URLs, logs, or browser history.
  """
  use BracketWeb, :controller

  # Phoenix.Token max age: 30 seconds is plenty for the redirect round-trip
  @token_max_age 30

  def set_host(conn, %{"session_token" => signed}) do
    case Phoenix.Token.verify(conn, "host_session", signed, max_age: @token_max_age) do
      {:ok, %{"id" => id, "token" => host_token}} ->
        case Bracket.BracketServer.validate_host_token(id, host_token) do
          :ok ->
            conn
            |> put_session("host_token", host_token)
            |> redirect(to: ~p"/bracket/#{id}")

          {:error, :unauthorized} ->
            conn
            |> put_flash(:error, "Invalid host token.")
            |> redirect(to: ~p"/")
        end

      {:error, _} ->
        conn
        |> put_flash(:error, "Session token expired or invalid. Please try again.")
        |> redirect(to: ~p"/")
    end
  end

  def set_host(conn, _params) do
    conn
    |> put_flash(:error, "Missing parameters.")
    |> redirect(to: ~p"/")
  end

  def set_participant(conn, %{"session_token" => signed}) do
    case Phoenix.Token.verify(conn, "participant_session", signed, max_age: @token_max_age) do
      {:ok, %{"id" => id, "participant_id" => participant_id}} ->
        conn
        |> put_session("participant_id_#{id}", participant_id)
        |> redirect(to: ~p"/bracket/#{id}")

      {:error, _} ->
        conn
        |> put_flash(:error, "Session token expired or invalid. Please try again.")
        |> redirect(to: ~p"/")
    end
  end

  def set_participant(conn, _params) do
    conn
    |> put_flash(:error, "Missing parameters.")
    |> redirect(to: ~p"/")
  end
end
