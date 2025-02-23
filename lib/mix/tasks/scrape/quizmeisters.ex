defmodule Mix.Tasks.Scrape.Quizmeisters do
  use Mix.Task
  require Logger

  @shortdoc "Runs the Quizmeisters venue scraper"

  def run(_) do
    Logger.info("Starting Quizmeisters scraper...")

    # Ensure all dependencies are started
    Application.ensure_all_started(:trivia_advisor)

    case TriviaAdvisor.Scraping.Scrapers.Quizmeisters.run() do
      {:ok, venues} ->
        Logger.info("Successfully scraped #{length(venues)} venues")

      {:error, reason} ->
        Logger.error("Failed to scrape venues: #{inspect(reason)}")
    end
  end
end
