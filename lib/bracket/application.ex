defmodule Bracket.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BracketWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:bracket, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Bracket.PubSub},
      {Registry, keys: :unique, name: Bracket.Registry},
      {DynamicSupervisor, name: Bracket.DynamicSupervisor, strategy: :one_for_one, max_children: 1000},
      BracketWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Bracket.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BracketWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
