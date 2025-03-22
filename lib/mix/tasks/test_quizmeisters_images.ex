defmodule Mix.Tasks.TestQuizmeistersImages do
  use Mix.Task
  import Ecto.Query
  require Logger

  alias TriviaAdvisor.Repo
  alias TriviaAdvisor.Events.{Event, EventSource}
  alias TriviaAdvisor.Scraping.{Source}
  alias TriviaAdvisor.Scraping.Helpers.ImageDownloader

  @shortdoc "Tests image normalization fix for QuizMeisters venues"

  @impl Mix.Task
  def run(args) do
    # Parse options
    {opts, _, _} = OptionParser.parse(args,
      strict: [
        fix: :boolean,
        venue: :string,
        limit: :integer
      ]
    )

    fix_mode = Keyword.get(opts, :fix, false)
    venue_filter = Keyword.get(opts, :venue)
    limit = Keyword.get(opts, :limit, 10)

    # Start the required applications
    Application.ensure_all_started(:httpoison)
    [:postgrex, :ecto, :ecto_sql]
    |> Enum.each(&Application.ensure_all_started/1)

    # Start the Repo
    Repo.start_link()

    # Find the QuizMeisters source - try different possible name formats
    quizmeisters_source =
      try do
        Repo.get_by!(Source, name: "QuizMeisters")
      rescue
        Ecto.NoResultsError ->
          try do
            Repo.get_by!(Source, name: "Quizmeisters")
          rescue
            Ecto.NoResultsError ->
              try do
                Repo.get_by!(Source, name: "quizmeisters")
              rescue
                Ecto.NoResultsError ->
                  # List all sources to help with debugging
                  sources = Repo.all(from s in Source, select: s.name)
                  sources_list = Enum.join(sources, ", ")
                  Logger.error("Could not find QuizMeisters source. Available sources: #{sources_list}")
                  raise "Could not find QuizMeisters source. Available sources: #{sources_list}"
              end
          end
      end

    Logger.info("Found source: #{quizmeisters_source.name} (ID: #{quizmeisters_source.id})")
    Logger.info("Looking for QuizMeisters events with problematic hero image filenames...")

    # Build the base query for QuizMeisters events with hero_image
    query = from e in Event,
      join: es in EventSource, on: es.event_id == e.id,
      join: v in assoc(e, :venue),
      where: es.source_id == ^quizmeisters_source.id and not is_nil(e.hero_image),
      preload: [:venue]

    # Apply venue filter if provided
    query = if venue_filter do
      Logger.info("Filtering by venue name containing: '#{venue_filter}'")
      from [e, es, v] in query,
        where: ilike(v.name, ^"%#{venue_filter}%")
    else
      query
    end

    # Apply limit
    query = from q in query, limit: ^limit

    # Execute query
    events = Repo.all(query)

    Logger.info("Found #{length(events)} QuizMeisters events with hero images")

    # Investigate the structure of hero_image field
    case events do
      [first | _] ->
        Logger.info("Sample hero_image structure: #{inspect(first.hero_image)}")
      [] ->
        Logger.warning("No events found to analyze hero_image structure", [])
    end

    # Check for problematic filenames
    problematic_events = Enum.filter(events, fn event ->
      # Handle hero_image as either string or map
      filename = case event.hero_image do
        %{file_name: file_name} -> file_name
        file_name when is_binary(file_name) -> file_name
        other ->
          Logger.warning("Unexpected hero_image format: #{inspect(other)}", [])
          nil
      end

      if filename do
        String.contains?(filename, ["%20", " "]) or
        String.contains?(filename, "--") or
        String.contains?(filename, "+") or
        String.contains?(filename, "?")
      else
        false
      end
    end)

    Logger.info("Found #{length(problematic_events)} events with problematic filenames")

    events_to_process = if length(problematic_events) == 0 do
      Logger.info("No problematic events found. Testing on the first few regular events instead.")
      Enum.take(events, 5)
    else
      problematic_events
    end

    mode_text = if fix_mode, do: "FIXING", else: "Testing"
    Logger.info("#{mode_text} #{length(events_to_process)} events")

    # Initialize counters for summary
    results = %{
      processed: 0,
      would_be_fixed: 0,
      already_fixed: 0,
      successful_fixes: 0,
      failed_fixes: 0,
      errors: 0,
      download_errors: 0
    }

    # Process each problematic event
    results = Enum.reduce(events_to_process, results, fn event, acc ->
      hero_image = case event.hero_image do
        %{file_name: file_name} -> file_name
        file_name when is_binary(file_name) -> file_name
        other ->
          Logger.warning("Unexpected hero_image format: #{inspect(other)}", [])
          "unknown"
      end

      Logger.info("#{mode_text} event: #{event.id} for venue: #{event.venue.name}")
      Logger.info("Current hero_image: #{hero_image}")

      # Find original image URL from event source metadata
      event_source = Repo.one(
        from es in EventSource,
        where: es.event_id == ^event.id and es.source_id == ^quizmeisters_source.id,
        select: es
      )

      hero_image_url = get_in(event_source.metadata, ["hero_image_url"])

      new_acc = %{acc | processed: acc.processed + 1}

      result = if hero_image_url do
        Logger.info("Found original hero_image_url: #{hero_image_url}")

        # Manual normalization of the filename from the URL
        # This is what ImageDownloader would do if it could download
        normalized_filename =
          hero_image_url
          |> URI.parse()
          |> Map.get(:path, "")
          |> Path.basename()
          |> normalize_filename()

        extension = Path.extname(hero_image_url) |> String.downcase()
        normalized_filename = if extension == "", do: normalized_filename <> ".jpg", else: normalized_filename

        Logger.info("Manually normalized filename: #{normalized_filename}")

        # Try downloading and normalizing the image, but fallback to manual normalization
        upload_result = try do
          ImageDownloader.download_event_hero_image(hero_image_url)
        rescue
          e ->
            Logger.error("Error downloading image: #{Exception.message(e)}")
            {:error, :download_error}
        end

        case upload_result do
          {:ok, upload} ->
            Logger.info("Successfully downloaded image with normalized filename: #{upload.filename}")

            # Compare with current filename
            if upload.filename != hero_image do
              Logger.info("✅ Filename would be fixed:")
              Logger.info("  Old: #{hero_image}")
              Logger.info("  New: #{upload.filename}")

              # Do a visual comparison to see the differences
              old_parts = String.split(hero_image, ["_", "-", "."])
              new_parts = String.split(upload.filename, ["_", "-", "."])

              Logger.info("Old parts: #{inspect(old_parts)}")
              Logger.info("New parts: #{inspect(new_parts)}")

              would_be_fixed_acc = %{new_acc | would_be_fixed: new_acc.would_be_fixed + 1}

              # If in fix mode, update the event with the new hero_image filename
              if fix_mode do
                case update_event_hero_image(event, upload) do
                  {:ok, updated_event} ->
                    updated_hero_image = case updated_event.hero_image do
                      %{file_name: file_name} -> file_name
                      file_name when is_binary(file_name) -> file_name
                      _ -> "unknown"
                    end
                    Logger.info("✅ Successfully updated event with new hero_image: #{updated_hero_image}")
                    %{would_be_fixed_acc | successful_fixes: would_be_fixed_acc.successful_fixes + 1}
                  {:error, changeset} ->
                    Logger.error("❌ Failed to update event: #{inspect(changeset.errors)}")
                    %{would_be_fixed_acc | failed_fixes: would_be_fixed_acc.failed_fixes + 1}
                end
              else
                would_be_fixed_acc
              end
            else
              Logger.info("❌ No change in filename, may already be fixed")
              %{new_acc | already_fixed: new_acc.already_fixed + 1}
            end

          {:error, reason} ->
            Logger.warning("Failed to download image: #{inspect(reason)}", [])
            Logger.info("Using manually normalized filename instead")

            # Compare with current filename using manually normalized version
            if normalized_filename != hero_image do
              Logger.info("✅ Filename would be fixed:")
              Logger.info("  Old: #{hero_image}")
              Logger.info("  New: #{normalized_filename}")

              # Do a visual comparison
              old_parts = String.split(hero_image, ["_", "-", "."])
              new_parts = String.split(normalized_filename, ["_", "-", "."])

              Logger.info("Old parts: #{inspect(old_parts)}")
              Logger.info("New parts: #{inspect(new_parts)}")

              would_be_fixed_acc = %{new_acc | would_be_fixed: new_acc.would_be_fixed + 1, download_errors: new_acc.download_errors + 1}

              # If in fix mode, update using the manually normalized filename
              if fix_mode do
                # Create a fake upload struct with the normalized filename
                fake_upload = %{filename: normalized_filename}
                case update_event_hero_image(event, fake_upload) do
                  {:ok, updated_event} ->
                    updated_hero_image = case updated_event.hero_image do
                      %{file_name: file_name} -> file_name
                      file_name when is_binary(file_name) -> file_name
                      _ -> "unknown"
                    end
                    Logger.info("✅ Successfully updated event with new hero_image: #{updated_hero_image}")
                    %{would_be_fixed_acc | successful_fixes: would_be_fixed_acc.successful_fixes + 1}
                  {:error, changeset} ->
                    Logger.error("❌ Failed to update event: #{inspect(changeset.errors)}")
                    %{would_be_fixed_acc | failed_fixes: would_be_fixed_acc.failed_fixes + 1}
                end
              else
                would_be_fixed_acc
              end
            else
              Logger.info("❌ No change in filename (manual normalization), may already be fixed")
              %{new_acc | already_fixed: new_acc.already_fixed + 1, download_errors: new_acc.download_errors + 1}
            end
        end
      else
        Logger.warning("No hero_image_url found in metadata for event #{event.id}", [])
        %{new_acc | errors: new_acc.errors + 1}
      end

      Logger.info(String.duplicate("-", 50))
      result
    end)

    # Print summary
    Logger.info("\n" <> String.duplicate("=", 50))
    Logger.info("SUMMARY")
    Logger.info(String.duplicate("=", 50))
    Logger.info("Total events processed: #{results.processed}")
    Logger.info("Events that would be fixed: #{results.would_be_fixed}")
    Logger.info("Events already normalized: #{results.already_fixed}")
    Logger.info("Events with download errors but potentially fixable: #{results.download_errors}")

    if fix_mode do
      Logger.info("Successful fixes: #{results.successful_fixes}")
      Logger.info("Failed fixes: #{results.failed_fixes}")
    end

    Logger.info("Errors: #{results.errors}")
    Logger.info(String.duplicate("=", 50))

    # Provide sample command to run in fix mode if not already in fix mode
    unless fix_mode do
      venue_option = if venue_filter, do: " --venue=\"#{venue_filter}\"", else: ""
      Logger.info("\nTo fix these issues, run:")
      Logger.info("mix test_quizmeisters_images --fix#{venue_option}")
    end

    Logger.info("\nTest completed")
  end

  # Manual implementation of normalize_filename to avoid dependency on ImageDownloader
  defp normalize_filename(filename) when is_binary(filename) do
    filename
    |> URI.decode() # Decode URL-encoded characters
    |> String.split("?") |> List.first() # Remove query parameters
    |> String.replace(~r/\s+/, "-") # Replace spaces with dashes
    |> String.replace(~r/\%20|\+/, "-") # Replace %20 or + with dash
    |> String.replace(~r/-+/, "-") # Replace multiple dashes with single dash
    |> String.downcase() # Ensure consistent case
  end
  defp normalize_filename(nil), do: ""
  defp normalize_filename(_), do: ""

  # Update the event with the new hero_image
  defp update_event_hero_image(event, upload) do
    # Handle the case where hero_image is a map or string
    new_hero_image = case event.hero_image do
      %{file_name: _} ->
        # It's a map structure, update just the file_name
        Map.put(event.hero_image, :file_name, upload.filename)
      _ when is_binary(event.hero_image) ->
        # It's a string, replace it
        upload.filename
      _ ->
        # Unknown format, use the new filename
        upload.filename
    end

    event
    |> Ecto.Changeset.change(%{hero_image: new_hero_image})
    |> Repo.update()
  end
end
