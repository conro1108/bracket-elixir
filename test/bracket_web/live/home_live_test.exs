defmodule BracketWeb.HomeLiveTest do
  use BracketWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # Helpers

  defp fill_form(view, name, host_name) do
    view |> element("#bracket-form") |> render_change(%{"name" => name, "host_name" => host_name})
  end

  defp add_item(view, item) do
    view |> element("form[phx-submit='add_item_submit']") |> render_submit(%{"new_item" => item})
  end

  defp bulk_paste(view, text) do
    view |> element("textarea[name='bulk_input']") |> render_change(%{"bulk_input" => text})
  end

  defp fill_ready_form(view, items \\ ~w[Alpha Beta Gamma Delta]) do
    fill_form(view, "Test Bracket", "Alice")
    bulk_paste(view, Enum.join(items, "\n"))
  end

  # Section 3.1 — HomeLive bracket creation tests

  describe "mount" do
    test "renders the creation form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "h1", "Bracket")
      assert has_element?(view, "input#bracket-name")
      assert has_element?(view, "input#host-name")
      assert has_element?(view, "button", "Create Bracket")
    end

    test "shows empty state message when no items", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "[class*='border-dashed']", "Add at least 4 items")
    end
  end

  describe "adding items" do
    test "adds an item via form submit (Add button or Enter key)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      add_item(view, "Pizza")

      assert has_element?(view, "span", "Pizza")
    end

    test "does not add duplicate items", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      add_item(view, "Pizza")
      add_item(view, "Pizza")

      # Only one list item should exist (duplicate was rejected)
      html = render(view)
      li_count = (html |> String.split("<li ") |> length()) - 1
      assert li_count == 1
    end

    test "removes an item by index", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      add_item(view, "Pizza")
      add_item(view, "Sushi")

      assert has_element?(view, "span", "Pizza")

      view |> element("button[phx-value-index='0']") |> render_click()

      refute has_element?(view, "span", "Pizza")
      assert has_element?(view, "span", "Sushi")
    end
  end

  describe "bulk paste" do
    test "parses newline-separated items", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      bulk_paste(view, "Pizza\nSushi\nTacos\nBurgers")

      assert has_element?(view, "span", "Pizza")
      assert has_element?(view, "span", "Sushi")
      assert has_element?(view, "span", "Tacos")
      assert has_element?(view, "span", "Burgers")
    end

    test "deduplicates items from bulk paste", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      add_item(view, "Pizza")
      bulk_paste(view, "Pizza\nSushi\nTacos\nBurgers")

      # Pizza should appear only once (was already in the list)
      html = render(view)
      pizza_count = html |> String.split(">Pizza<") |> length() |> Kernel.-(1)
      assert pizza_count == 1
    end
  end

  describe "validation" do
    test "shows gentle hint when fewer than 4 items", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      add_item(view, "Pizza")
      add_item(view, "Sushi")

      # Gentle hint, not an error
      assert has_element?(view, "p", ~r/more needed/)
      refute has_element?(view, "p.text-error")
    end

    test "shows warning when more than 32 items", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      items = Enum.map(1..33, &"Item #{&1}") |> Enum.join("\n")
      bulk_paste(view, items)

      assert has_element?(view, "p", ~r/Too many/)
    end

    test "no errors shown on fresh form", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      refute html =~ "text-error"
    end

    test "create button is disabled when form is not ready", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~r/disabled/
    end

    test "create button is enabled when name, items (>=4), and host name are filled", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      fill_ready_form(view)

      html = render(view)
      refute Regex.match?(~r/<button[^>]*disabled[^>]*>.*Create Bracket/s, html)
    end

    test "create button is enabled with 7 items (non-power-of-2, gets a bye)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      fill_ready_form(view, ~w[Alpha Beta Gamma Delta Epsilon Zeta Eta])

      html = render(view)
      refute Regex.match?(~r/<button[^>]*disabled[^>]*>.*Create Bracket/s, html)
    end
  end

  describe "create bracket (smoke test)" do
    @tag :smoke
    test "submits form and redirects to bracket", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      fill_ready_form(view)

      view |> element("#bracket-form") |> render_submit(%{"name" => "Test Bracket", "host_name" => "Alice"})

      {path, _flash} = assert_redirect(view)
      assert String.starts_with?(path, "/session/host")
    end

    @tag :smoke
    test "creates bracket with non-power-of-2 item count (bye assigned)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      fill_ready_form(view, ~w[Alpha Beta Gamma Delta Epsilon Zeta Eta])

      view |> element("#bracket-form") |> render_submit(%{"name" => "Test Bracket", "host_name" => "Alice"})

      {path, _flash} = assert_redirect(view)
      assert String.starts_with?(path, "/session/host")
    end
  end
end
