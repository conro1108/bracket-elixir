defmodule Bracket.Sanitizer do
  @moduledoc """
  Input sanitization utilities for user-supplied strings.
  Trims whitespace and enforces length limits.

  Note: HTML-escaping is intentionally omitted. Phoenix LiveView's HEEx templates
  automatically escape all interpolated values, so escaping here would cause
  double-escaping (e.g. "&" → "&amp;amp;").
  """

  @doc """
  Sanitizes a single string: trims whitespace and truncates to `max_length` characters.
  """
  @spec sanitize(String.t(), pos_integer()) :: String.t()
  def sanitize(string, max_length) when is_binary(string) and is_integer(max_length) do
    string
    |> String.trim()
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
end
