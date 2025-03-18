import Config

# Note we also include the path to a cache manifest
# containing the digested version of static files. This
# manifest is generated by the `mix assets.deploy` task,
# which you should run after static files are built and
# before starting your production server.
config :trivia_advisor, TriviaAdvisorWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

# Configures Swoosh API Client
config :swoosh, api_client: Swoosh.ApiClient.Finch, finch_name: TriviaAdvisor.Finch

# Disable Swoosh Local Memory Storage
config :swoosh, local: false

# Do not print debug messages in production
config :logger, level: :info

# Set environment tag
config :trivia_advisor, env: :prod

# Add cron jobs only in production
config :trivia_advisor, Oban,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 1 * * *", TriviaAdvisor.Scraping.Oban.QuestionOneIndexJob}, # Run at 2 AM daily
       {"0 2 * * *", TriviaAdvisor.Scraping.Oban.QuizmeistersIndexJob}, # Run at 3 AM daily
       {"0 3 * * *", TriviaAdvisor.Scraping.Oban.InquizitionIndexJob}, # Run at 4 AM daily
       {"0 4 * * *", TriviaAdvisor.Scraping.Oban.SpeedQuizzingIndexJob}, # Run at 5 AM daily with limit=100
       {"0 5 * * *", TriviaAdvisor.Scraping.Oban.GeeksWhoDrinkIndexJob},
       {"0 6 * * *", TriviaAdvisor.Scraping.Oban.PubquizIndexJob}, # Run at 6 AM daily
       {"0 2 * * *", TriviaAdvisor.Locations.Oban.DailyRecalibrateWorker}, # Run at 2 AM daily
       {"0 1 * * *", TriviaAdvisor.Workers.UnsplashImageRefresher, args: %{"action" => "refresh"}} # Run at 1 AM daily
     ]},
    {Oban.Plugins.Pruner, max_age: 604800}  # 7 days in seconds
  ]

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
