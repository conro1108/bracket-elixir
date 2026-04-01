defmodule BracketWeb.Router do
  use BracketWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BracketWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", BracketWeb do
    pipe_through :browser

    live "/", HomeLive
    live "/bracket/:id", BracketLive
    live "/bracket/:id/host", BracketLive, :host_recovery

    get "/health", HealthController, :index
    get "/session/host", SessionController, :set_host
    get "/session/participant", SessionController, :set_participant
  end

  # Other scopes may use custom stacks.
  # scope "/api", BracketWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:bracket, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: BracketWeb.Telemetry
    end
  end
end
