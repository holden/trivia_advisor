defmodule TriviaAdvisorWeb.Router do
  use TriviaAdvisorWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TriviaAdvisorWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", TriviaAdvisorWeb do
    pipe_through :browser

    live "/", HomeLive.Index, :index
    live "/cities/:slug", CityLive.Show, :show
    live "/cities", CityLive.Index, :index
    live "/venues/:id", VenueLive.Show, :show

    # Admin route for image cache management (only in dev)
    if Mix.env() == :dev do
      live "/dev/cache", DevLive.Cache, :index
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", TriviaAdvisorWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:trivia_advisor, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TriviaAdvisorWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
