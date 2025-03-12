defmodule TriviaAdvisor.Scraping.Oban.QuizmeistersIndexJob do
  use Oban.Worker,
    queue: :default,
    max_attempts: TriviaAdvisor.Scraping.RateLimiter.max_attempts(),
    priority: TriviaAdvisor.Scraping.RateLimiter.priority()

  require Logger

  # Aliases for the Quizmeisters scraper functionality
  alias TriviaAdvisor.Repo
  alias TriviaAdvisor.Scraping.Source
  alias TriviaAdvisor.Scraping.RateLimiter

  # Strict timeout values to prevent hanging requests
  @http_options [
    follow_redirect: true,
    timeout: 15_000,        # 15 seconds for connect timeout
    recv_timeout: 15_000,   # 15 seconds for receive timeout
    hackney: [pool: false]  # Don't use connection pooling for scrapers
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    Logger.info("🔄 Starting Quizmeisters Index Job...")

    # Check if a limit is specified (for testing)
    limit = Map.get(args, "limit")

    # Get the Quizmeisters source
    source = Repo.get_by!(Source, website_url: "https://quizmeisters.com")

    # Call the existing fetch_venues function to get the venue list
    case fetch_venues() do
      {:ok, venues} ->
        # Log the number of venues found
        venue_count = length(venues)
        Logger.info("✅ Successfully fetched #{venue_count} venues from Quizmeisters")

        # Apply limit if specified
        venues_to_process = if limit, do: Enum.take(venues, limit), else: venues
        limited_count = length(venues_to_process)

        if limit do
          Logger.info("🧪 Testing mode: Limited to #{limited_count} venues (out of #{venue_count} total)")
        end

        # Enqueue detail jobs for each venue with rate limiting
        enqueued_count = enqueue_detail_jobs_with_rate_limiting(venues_to_process, source.id)
        Logger.info("✅ Enqueued #{enqueued_count} detail jobs for processing with rate limiting")

        # Return success with venue count
        {:ok, %{venue_count: venue_count, enqueued_jobs: enqueued_count, source_id: source.id}}

      {:error, reason} ->
        # Log the error
        Logger.error("❌ Failed to fetch Quizmeisters venues: #{inspect(reason)}")

        # Return the error
        {:error, reason}
    end
  end

  # Enqueue detail jobs for each venue with rate limiting
  defp enqueue_detail_jobs_with_rate_limiting(venues, source_id) do
    Logger.info("🔄 Enqueueing detail jobs for #{length(venues)} venues with rate limiting...")

    # Use the RateLimiter to schedule jobs with a delay
    RateLimiter.schedule_detail_jobs(
      venues,
      TriviaAdvisor.Scraping.Oban.QuizmeistersDetailJob,
      fn venue ->
        %{
          venue: venue,
          source_id: source_id
        }
      end
    )
  end

  # The following function is copied from the existing Quizmeisters scraper
  # to avoid modifying the original code
  defp fetch_venues do
    api_url = "https://storerocket.io/api/user/kDJ3BbK4mn/locations"

    # Create a task with timeout for the API request
    task = Task.async(fn ->
      case HTTPoison.get(api_url, [], @http_options) do
        {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"results" => %{"locations" => locations}}} when is_list(locations) ->
              {:ok, locations}

            {:error, reason} ->
              Logger.error("Failed to parse JSON response: #{inspect(reason)}")
              {:error, "Failed to parse JSON response"}

            _ ->
              Logger.error("Unexpected response format")
              {:error, "Unexpected response format"}
          end

        {:ok, %HTTPoison.Response{status_code: status}} ->
          Logger.error("HTTP #{status}: Failed to fetch venues")
          {:error, "HTTP #{status}"}

        {:error, %HTTPoison.Error{reason: :timeout}} ->
          Logger.error("Timeout fetching Quizmeisters venues")
          {:error, "HTTP request timeout"}

        {:error, %HTTPoison.Error{reason: :connect_timeout}} ->
          Logger.error("Connection timeout fetching Quizmeisters venues")
          {:error, "HTTP connection timeout"}

        {:error, reason} ->
          Logger.error("Request failed: #{inspect(reason)}")
          {:error, "Request failed: #{inspect(reason)}"}
      end
    end)

    # Wait for the task with a hard timeout
    case Task.yield(task, 30_000) || Task.shutdown(task) do
      {:ok, result} -> result
      nil ->
        Logger.error("Task timeout when fetching Quizmeisters venues")
        {:error, "Task timeout"}
    end
  end
end
