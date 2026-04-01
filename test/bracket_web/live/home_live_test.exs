defmodule BracketWeb.HomeLiveTest do
  use BracketWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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
    test "adds an item on Enter keypress", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("input[name='new_item']")
      |> render_keyup(%{"key" => "Enter", "value" => "Pizza"})

      assert has_element?(view, "span", "Pizza")
    end

    test "does not add duplicate items", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("input[name='new_item']") |> render_keyup(%{"key" => "Enter", "value" => "Pizza"})
      view |> element("input[name='new_item']") |> render_keyup(%{"key" => "Enter", "value" => "Pizza"})

      # Only one list item should exist (duplicate was rejected)
      html = render(view)
      li_count = (html |> String.split("<li ") |> length()) - 1
      assert li_count == 1
    end

    test "removes an item by index", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("input[name='new_item']") |> render_keyup(%{"key" => "Enter", "value" => "Pizza"})
      view |> element("input[name='new_item']") |> render_keyup(%{"key" => "Enter", "value" => "Sushi"})

      assert has_element?(view, "span", "Pizza")

      view |> element("button[phx-value-index='0']") |> render_click()

      refute has_element?(view, "span", "Pizza")
      assert has_element?(view, "span", "Sushi")
    end
  end

  describe "bulk paste" do
    test "parses newline-separated items", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("textarea[name='bulk_input']")
      |> render_change(%{"bulk_input" => "Pizza\nSushi\nTacos\nBurgers"})

      assert has_element?(view, "span", "Pizza")
      assert has_element?(view, "span", "Sushi")
      assert has_element?(view, "span", "Tacos")
      assert has_element?(view, "span", "Burgers")
    end

    test "deduplicates items from bulk paste", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("input[name='new_item']")
      |> render_keyup(%{"key" => "Enter", "value" => "Pizza"})

      view
      |> element("textarea[name='bulk_input']")
      |> render_change(%{"bulk_input" => "Pizza\nSushi\nTacos\nBurgers"})

      # Pizza should appear only once (was already in the list)
      html = render(view)
      pizza_count = html |> String.split(">Pizza<") |> length() |> Kernel.-(1)
      assert pizza_count == 1
    end
  end

  describe "validation" do
    test "shows error when fewer than 4 items", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("input[name='new_item']") |> render_keyup(%{"key" => "Enter", "value" => "Pizza"})
      view |> element("input[name='new_item']") |> render_keyup(%{"key" => "Enter", "value" => "Sushi"})
      view |> element("input[name='new_item']") |> render_keyup(%{"key" => "Enter", "value" => "Tacos"})

      view |> element("input[name='name']") |> render_change(%{"value" => "My Bracket"})
      view |> element("input[name='host_name']") |> render_change(%{"value" => "Alice"})

      assert has_element?(view, "p.text-error", ~r/at least 4/)
    end

    test "shows error when more than 32 items", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Add 33 items via bulk paste
      items = Enum.map(1..33, &"Item #{&1}") |> Enum.join("\n")

      view
      |> element("textarea[name='bulk_input']")
      |> render_change(%{"bulk_input" => items})

      assert has_element?(view, "p.text-error", ~r/Maximum 32/)
    end

    test "shows error when bracket name is empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("input[name='name']") |> render_change(%{"value" => ""})

      assert has_element?(view, "p.text-error", ~r/required/)
    end

    test "create button is disabled when form is not ready", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~r/disabled/
    end
  end

  describe "create bracket (smoke test)" do
    @tag :smoke
    test "submits form and redirects to bracket", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Fill in name
      view |> element("input[name='name']") |> render_change(%{"value" => "Test Bracket"})

      # Add 4 items via bulk paste
      view
      |> element("textarea[name='bulk_input']")
      |> render_change(%{"bulk_input" => "Alpha\nBeta\nGamma\nDelta"})

      # Fill in host name
      view |> element("input[name='host_name']") |> render_change(%{"value" => "Alice"})

      # Submit — this will redirect through SessionController
      # In test environment, redirect to /session/host is followed
      view |> element("button[phx-click='create']") |> render_click()

      # Should redirect to /session/host (which sets the cookie then goes to /bracket/:id)
      {path, _flash} = assert_redirect(view)
      assert String.starts_with?(path, "/session/host")
    end
  end
end
