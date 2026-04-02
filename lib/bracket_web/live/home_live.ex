defmodule BracketWeb.HomeLive do
  use BracketWeb, :live_view

  @max_items 32
  @min_items 4
  @max_name_length 100
  @max_item_length 100

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Create Bracket",
       name: "",
       items: [],
       new_item: "",
       host_name: "",
       bulk_input: "",
       errors: %{},
       loading: false,
       min_items: @min_items,
       max_name_length: @max_name_length,
       max_items: @max_items,
       max_item_length: @max_item_length
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100 flex items-center justify-center p-4">
      <div class="w-full max-w-lg">
        <div class="text-center mb-8">
          <h1 class="text-4xl font-bold text-primary mb-2" tabindex="-1" data-focus-target>
            Bracket
          </h1>
          <p class="text-base-content/70">Create a real-time tournament for any topic</p>
        </div>

        <div class="card bg-base-200 shadow-xl">
          <div class="card-body gap-6">
            <form id="bracket-form" phx-change="form_changed" phx-submit="create">
              <%!-- Bracket Name --%>
              <div class="fieldset mb-6">
                <label for="bracket-name" class="label mb-1">Bracket Name</label>
                <input
                  id="bracket-name"
                  type="text"
                  name="name"
                  value={@name}
                  maxlength={@max_name_length}
                  placeholder="e.g. Best Pizza Toppings"
                  class="w-full input"
                  phx-debounce="300"
                />
              </div>

              <%!-- Host Name --%>
              <div class="fieldset mb-6">
                <label for="host-name" class="label mb-1">Your Display Name</label>
                <input
                  id="host-name"
                  type="text"
                  name="host_name"
                  value={@host_name}
                  maxlength="30"
                  placeholder="Your name"
                  class="w-full input"
                  phx-debounce="300"
                />
              </div>

              <%!-- Hidden submit so the outer form can be submitted by the Create button --%>
              <input type="submit" class="hidden" />
            </form>

            <%!-- Items List --%>
            <div class="fieldset">
              <span class="label mb-1">Items <span class="text-base-content/50 text-xs">({length(@items)} / {@max_items})</span></span>

              <div :if={@items == []} class="text-center py-6 text-base-content/50 border-2 border-dashed border-base-300 rounded-lg">
                Add at least 4 items to get started
              </div>

              <ul :if={@items != []} class="space-y-2 mb-3">
                <li :for={{item, idx} <- Enum.with_index(@items)} class="flex items-center gap-2">
                  <span class="flex-1 px-3 py-2 bg-base-100 rounded-lg text-sm truncate">{item}</span>
                  <button
                    type="button"
                    class="btn btn-ghost btn-sm btn-square"
                    aria-label={"Remove #{item}"}
                    phx-click="remove_item"
                    phx-value-index={idx}
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </li>
              </ul>

              <form phx-submit="add_item_submit" class="flex gap-2">
                <input
                  id="new-item-input"
                  type="text"
                  name="new_item"
                  placeholder="Add an item..."
                  maxlength={@max_item_length}
                  class="flex-1 input input-sm"
                />
                <button type="submit" class="btn btn-sm btn-primary">
                  Add
                </button>
              </form>

              <p :if={length(@items) > 0 and length(@items) < @min_items} class="mt-1 text-sm text-base-content/50">
                {@min_items - length(@items)} more needed
              </p>
              <p :if={length(@items) > @max_items} class="mt-1 text-sm text-warning">
                Too many items (max {@max_items})
              </p>
            </div>

            <%!-- Bulk Paste --%>
            <details class="fieldset">
              <summary class="label cursor-pointer select-none">Bulk paste items</summary>
              <div class="mt-2 space-y-2">
                <textarea
                  id="bulk-input"
                  name="bulk_input"
                  rows="4"
                  placeholder={"Paste one item per line:\nPizza\nSushi\nTacos\nBurgers"}
                  class="w-full textarea textarea-sm"
                  phx-change="bulk_paste"
                  phx-debounce="500"
                >{@bulk_input}</textarea>
                <p class="text-xs text-base-content/50">One item per line. Duplicates will be removed.</p>
              </div>
            </details>

            <%!-- Submit --%>
            <button
              type="submit"
              form="bracket-form"
              class="btn btn-primary btn-lg w-full"
              disabled={@loading || !form_ready?(@name, @items, @host_name)}
            >
              <span :if={@loading}>
                <.icon name="hero-arrow-path" class="size-5 animate-spin" />
                Creating...
              </span>
              <span :if={!@loading}>Create Bracket</span>
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("form_changed", params, socket) do
    name = params |> Map.get("name", socket.assigns.name) |> String.slice(0, @max_name_length)
    host_name = params |> Map.get("host_name", socket.assigns.host_name) |> String.slice(0, 30)

    {:noreply, assign(socket, name: name, host_name: host_name)}
  end

  def handle_event("add_item_submit", %{"new_item" => value}, socket) do
    add_item(value, socket)
  end

  def handle_event("remove_item", %{"index" => index_str}, socket) do
    case Integer.parse(index_str) do
      {index, _} ->
        new_items = List.delete_at(socket.assigns.items, index)
        {:noreply, assign(socket, items: new_items)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("bulk_paste", %{"bulk_input" => raw}, socket) do
    new_items =
      raw
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.slice(&1, 0, @max_item_length))
      |> Enum.uniq()

    merged =
      (socket.assigns.items ++ new_items)
      |> Enum.uniq()

    {:noreply, assign(socket, items: merged, bulk_input: raw)}
  end

  def handle_event("create", params, socket) do
    # Pull latest values from the form submission params in case phx-change was debounced
    name = params |> Map.get("name", socket.assigns.name) |> String.slice(0, @max_name_length)
    host_name = params |> Map.get("host_name", socket.assigns.host_name) |> String.slice(0, 30)
    items = socket.assigns.items

    errors =
      %{}
      |> validate_name(name)
      |> validate_items(items)
      |> validate_host_name(host_name)

    if has_errors?(errors) or not form_ready?(name, items, host_name) do
      {:noreply, assign(socket, name: name, host_name: host_name, errors: errors)}
    else
      socket = assign(socket, name: name, host_name: host_name, loading: true)

      case Bracket.BracketServer.create(%{name: name, items: items, host_name: host_name}) do
        {:ok, id, host_token} ->
          signed =
            Phoenix.Token.sign(socket, "host_session", %{"id" => id, "token" => host_token})

          {:noreply,
           socket
           |> redirect(to: ~p"/session/host?session_token=#{signed}")}

        {:error, reason} ->
          error_msg = format_error(reason)

          {:noreply,
           socket
           |> assign(loading: false, errors: Map.put(errors, :general, error_msg))}
      end
    end
  end

  # Private helpers

  defp add_item(value, socket) do
    item = value |> String.trim() |> String.slice(0, @max_item_length)

    if item == "" do
      {:noreply, socket}
    else
      items = socket.assigns.items

      if item in items do
        {:noreply, socket}
      else
        new_items = items ++ [item]

        {:noreply,
         socket
         |> assign(items: new_items)
         |> push_event("clear_input", %{id: "new-item-input"})}
      end
    end
  end

  defp validate_name(errors, name) do
    cond do
      name == "" -> Map.put(errors, :name, "Bracket name is required")
      String.length(name) > @max_name_length -> Map.put(errors, :name, "Name is too long (max #{@max_name_length} characters)")
      true -> Map.delete(errors, :name)
    end
  end

  defp validate_items(errors, items) do
    count = length(items)

    cond do
      count < @min_items and count > 0 ->
        Map.put(errors, :items, "Add at least #{@min_items} items (#{count} added so far)")

      count > @max_items ->
        Map.put(errors, :items, "Maximum #{@max_items} items allowed")

      true ->
        Map.delete(errors, :items)
    end
  end

  defp validate_host_name(errors, host_name) do
    if host_name == "" do
      Map.put(errors, :host_name, "Your display name is required")
    else
      Map.delete(errors, :host_name)
    end
  end

  defp has_errors?(errors), do: map_size(errors) > 0

  defp form_ready?(name, items, host_name) do
    name != "" and length(items) >= @min_items and host_name != ""
  end

  defp format_error(:too_few_items), do: "Not enough items (minimum #{@min_items})"
  defp format_error(:too_many_items), do: "Too many items (maximum #{@max_items})"
  defp format_error(:invalid_name), do: "Invalid bracket name"
  defp format_error(_), do: "Something went wrong, please try again"
end
