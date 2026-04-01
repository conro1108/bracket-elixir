defmodule Bracket.Sanitizer do
  @moduledoc """
  Input sanitization utilities for user-supplied strings.
  Trims whitespace, escapes HTML, and enforces length limits.
  """

  @doc """
  Sanitizes a single string: trims whitespace, HTML-escapes it, then truncates
  to `max_length` characters.
  """
  @spec sanitize(String.t(), pos_integer()) :: String.t()
  def sanitize(string, max_length) when is_binary(string) and is_integer(max_length) do
    string
    |> String.trim()
    |> html_escape()
    |> String.slice(0, max_length)
  end

  def sanitize(_, _), do: ""

  @doc """
  Sanitizes a list of item strings: sanitizes each one, removes empty strings,
  and deduplicates while preserving order.
  """
  @spec sanitize_items([String.t()]) :: [String.t()]
  def sanitize_items(items) when is_list(items) do
    items
    |> Enum.map(&sanitize(&1, 100))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def sanitize_items(_), do: []

  # Escapes HTML special characters to prevent XSS.
  defp html_escape(string) do
    string
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
