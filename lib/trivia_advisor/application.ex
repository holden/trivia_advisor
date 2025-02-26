defmodule TriviaAdvisor.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TriviaAdvisorWeb.Telemetry,
      TriviaAdvisor.Repo,
      {DNSCluster, query: Application.get_env(:trivia_advisor, :dns_cluster_query) || :ignore},
      {Oban, Application.fetch_env!(:trivia_advisor, Oban)},
      {Phoenix.PubSub, name: TriviaAdvisor.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: TriviaAdvisor.Finch},
      # Start the Unsplash service for image caching
      {TriviaAdvisor.Services.UnsplashService, []},
      # Start a worker by calling: TriviaAdvisor.Worker.start_link(arg)
      # {TriviaAdvisor.Worker, arg},
      # Start to serve requests, typically the last entry
      TriviaAdvisorWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TriviaAdvisor.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TriviaAdvisorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
