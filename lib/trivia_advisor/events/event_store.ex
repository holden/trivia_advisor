defmodule TriviaAdvisor.Events.EventStore do
  @moduledoc """
  Handles creating and updating events and their sources.
  """

  import Ecto.Query
  alias TriviaAdvisor.Repo
  alias TriviaAdvisor.Events.{Event, EventSource}
  require Logger

  # Import only the parse_currency function
  import Event, only: [parse_currency: 2]

  @doc """
  Process event data from a scraper, creating or updating the event and its source.
  If day_of_week changes, creates a new event instead of updating.
  """
  def process_event(venue, event_data, source_id) do
    # Ensure upload directory exists
    ensure_upload_dir()

    # Convert string keys to atoms for consistent access
    # This allows the function to work with both string and atom keys
    event_data = normalize_keys(event_data)

    # Log the performer_id from event_data
    Logger.info("🎭 Processing event for venue #{venue.name} with performer_id: #{inspect(Map.get(event_data, :performer_id))}")

    # Preload required associations
    venue = Repo.preload(venue, [city: :country])

    # Parse frequency from the raw title
    frequency = parse_event_frequency(event_data.raw_title)

    # Download and attach hero image if URL is present
    hero_image_attrs = case event_data.hero_image_url do
      url when is_binary(url) and url != "" ->
        case download_hero_image(url) do
          {:ok, upload} ->
            try do
              # Test if Waffle can process the image by checking file validity
              extension = Path.extname(upload.filename) |> String.downcase()

              # Check if image has valid extension, if not use the one we detected
              if extension == "" or not Regex.match?(~r/\.(jpg|jpeg|png|gif|webp)$/i, extension) do
                Logger.debug("Using detected extension for image without extension")
                # Get the detected extension from the content_type
                detected_ext = case upload.content_type do
                  "image/jpeg" -> ".jpg"
                  "image/png" -> ".png"
                  "image/gif" -> ".gif"
                  "image/webp" -> ".webp"
                  _ -> ".jpg" # Default to jpg
                end

                # Create a new upload struct with the filename + detected extension
                # But first check if the filename already ends with the correct extension to avoid duplication
                root_name = Path.rootname(upload.filename)
                filename_without_query = root_name |> String.split("?") |> List.first()

                # Re-normalize the filename to ensure consistent format between S3 and database
                alias TriviaAdvisor.Scraping.Helpers.ImageDownloader
                normalized_filename = ImageDownloader.normalize_filename(filename_without_query)

                # Only add extension if the filename doesn't already end with it
                new_filename = if String.ends_with?(String.downcase(normalized_filename), detected_ext) do
                  normalized_filename
                else
                  normalized_filename <> detected_ext
                end

                # Create the new Plug.Upload struct with the corrected filename
                new_upload = %Plug.Upload{
                  path: upload.path,
                  filename: new_filename,
                  content_type: upload.content_type
                }
                %{hero_image: new_upload}
              else
                # Original filename has valid extension
                %{hero_image: upload}
              end
            rescue
              err ->
                Logger.error("Error processing hero image: #{inspect(err)}")
                %{}
            end
          {:error, reason} ->
            Logger.warning("Failed to download hero image: #{inspect(reason)}")
            %{}
        end
      _ -> %{}
    end

    # Get performer_id from event_data, ensuring it's properly passed through
    performer_id = Map.get(event_data, :performer_id)
    Logger.info("🎭 Using performer_id: #{inspect(performer_id)} for event at venue: #{venue.name}")

    attrs = %{
      name: event_data.raw_title,  # Keep the raw title
      venue_id: venue.id,
      day_of_week: parse_day_of_week(event_data.time_text),
      start_time: parse_time(event_data.time_text),
      frequency: frequency,
      entry_fee_cents: parse_currency(event_data.fee_text, venue) || 0,  # Always default to 0 if nil
      description: event_data.description,
      performer_id: performer_id  # Use the extracted performer_id
    }
    |> Map.merge(hero_image_attrs)  # Merge in hero image if downloaded

    Logger.debug("🎭 Event attributes: #{inspect(attrs)}")

    Repo.transaction(fn ->
      # First try to find by venue and day
      existing_event = find_existing_event(attrs.venue_id, attrs.day_of_week)

      # Log the existing event if found
      if existing_event do
        Logger.info("🔄 Found existing event #{existing_event.id} for venue #{venue.name} on day #{attrs.day_of_week}")
        Logger.info("🎭 Existing event has performer_id: #{inspect(existing_event.performer_id)}")
      else
        Logger.info("🆕 Creating new event for venue #{venue.name} on day #{attrs.day_of_week}")
      end

      # Process the event
      result = case existing_event do
        nil -> create_event(attrs)
        event ->
          if event_changed?(event, attrs) do
            # Check if performer_id is changing
            if event.performer_id != attrs.performer_id do
              Logger.info("🎭 Updating performer_id from #{inspect(event.performer_id)} to #{inspect(attrs.performer_id)}")
            end
            update_event(event, attrs)
          else
            # If no changes, but performer_id is different, update just that field
            if not is_nil(attrs.performer_id) and event.performer_id != attrs.performer_id do
              Logger.info("🎭 Event not changed but performer_id is different. Updating just performer_id from #{inspect(event.performer_id)} to #{inspect(attrs.performer_id)}")
              event
              |> Ecto.Changeset.change(%{performer_id: attrs.performer_id})
              |> Repo.update()
            else
              {:ok, event}
            end
          end
      end

      case result do
        {:ok, event} ->
          # Log the result
          Logger.info("✅ Event processed successfully with ID: #{event.id}, performer_id: #{inspect(event.performer_id)}")

          # Pass all needed data to upsert_event_source
          case upsert_event_source(
            event.id,
            source_id,
            event_data.source_url,
            %{event_data: event_data, attrs: attrs, venue: venue, frequency: frequency}
          ) do
            {:ok, _source} -> {:ok, event}
            {:error, reason} ->
              Logger.error("Failed to upsert event source: #{inspect(reason)}")
              Repo.rollback(reason)
          end

        {:error, changeset} ->
          Logger.error("❌ Failed to process event: #{inspect(changeset.errors)}")

          # If the failure was specifically due to hero_image, try again without it
          if hero_image_error?(changeset) do
            Logger.warning("Retrying event creation without hero image due to validation error")
            # Remove hero_image from attrs and try again
            filtered_attrs = Map.drop(attrs, [:hero_image])
            case existing_event do
              nil -> create_event(filtered_attrs)
              event ->
                if event_changed?(event, filtered_attrs) do
                  update_event(event, filtered_attrs)
                else
                  {:ok, event}
                end
            end
            |> case do
              {:ok, event} ->
                # Pass all needed data to upsert_event_source
                case upsert_event_source(
                  event.id,
                  source_id,
                  event_data.source_url,
                  %{event_data: event_data, attrs: filtered_attrs, venue: venue, frequency: frequency}
                ) do
                  {:ok, _source} -> {:ok, event}
                  {:error, reason} -> Repo.rollback(reason)
                end
              {:error, reason} -> Repo.rollback(reason)
            end
          else
            Repo.rollback(changeset)
          end
      end
    end)
  end

  # Normalize keys to atoms for consistent access
  # This allows the function to work with both string and atom keys
  # Uses String.to_existing_atom first to prevent atom exhaustion risk
  defp normalize_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      atom_key = if is_binary(k) do
        try do
          String.to_existing_atom(k)
        rescue
          ArgumentError -> String.to_atom(k)  # Fallback when atom doesn't exist
        end
      else
        k
      end
      Map.put(acc, atom_key, v)
    end)
  end

  defp find_existing_event(venue_id, day_of_week) do
    Repo.one(
      from e in Event,
      where: e.venue_id == ^venue_id and
             e.day_of_week == ^day_of_week,
      limit: 1
    )
  end

  defp create_event(attrs) do
    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
  end

  defp update_event(event, attrs) do
    event
    |> Event.changeset(attrs)
    |> Repo.update()
  end

  defp upsert_event_source(event_id, source_id, source_url, data) do
    now = DateTime.utc_now()

    # Build metadata from event data
    metadata = %{
      raw_title: data.event_data.raw_title,
      clean_title: data.event_data.name,
      address: data.venue.address,
      time_text: data.event_data.time_text,
      day_of_week: data.attrs.day_of_week,
      start_time: data.attrs.start_time,
      frequency: data.frequency,
      fee_text: data.event_data.fee_text,
      phone: data.venue.phone,
      website: data.venue.website,
      description: data.event_data.description,
      hero_image_url: data.event_data.hero_image_url
    }

    case Repo.get_by(EventSource, event_id: event_id, source_id: source_id) do
      nil ->
        %EventSource{}
        |> EventSource.changeset(%{
          event_id: event_id,
          source_id: source_id,
          source_url: source_url,
          metadata: metadata,
          last_seen_at: now
        })
        |> Repo.insert()

      source ->
        source
        |> EventSource.changeset(%{
          source_url: source_url,
          metadata: metadata,
          last_seen_at: now
        })
        |> Repo.update()
    end
  end

  # Check if event has changed in a way that requires an update
  # Note: We're not including performer_id here because we want to update it separately
  # if it's the only thing that changed
  defp event_changed?(event, attrs) do
    Map.take(event, [:start_time, :frequency, :entry_fee_cents, :description]) !=
    Map.take(attrs, [:start_time, :frequency, :entry_fee_cents, :description])
  end

  defp parse_day_of_week("Monday" <> _), do: 1
  defp parse_day_of_week("Tuesday" <> _), do: 2
  defp parse_day_of_week("Wednesday" <> _), do: 3
  defp parse_day_of_week("Thursday" <> _), do: 4
  defp parse_day_of_week("Friday" <> _), do: 5
  defp parse_day_of_week("Saturday" <> _), do: 6
  defp parse_day_of_week("Sunday" <> _), do: 7

  defp parse_time(time_text) do
    # Extract time from format like "Wednesday 20:00"
    case Regex.run(~r/\d{2}:\d{2}/, time_text) do
      [time] -> Time.from_iso8601!(time <> ":00")
      nil -> raise "Invalid time format: #{time_text}"
    end
  end

  # Parse frequency from event title
  defp parse_event_frequency(title) do
    title = String.downcase(title)
    cond do
      # Check for explicit monthly patterns with ordinals
      (String.contains?(title, ["first", "second", "third", "fourth", "last"]) and
       String.contains?(title, ["of the month", "of every month"])) or
      String.contains?(title, ["monthly"]) ->
        :monthly

      # Check for biweekly/fortnightly patterns
      String.contains?(title, ["every other", "bi-weekly", "biweekly", "fortnightly"]) ->
        :biweekly

      # Everything else is weekly (default for pub quizzes)
      true ->
        :weekly
    end
  end

  # Check if the changeset error is specifically related to the hero_image
  defp hero_image_error?(changeset) do
    Enum.any?(changeset.errors, fn {field, _} -> field == :hero_image end)
  end

  # Download hero image from URL
  defp download_hero_image(url) do
    # Use the centralized ImageDownloader to ensure consistent filename handling
    alias TriviaAdvisor.Scraping.Helpers.ImageDownloader
    ImageDownloader.download_event_hero_image(url)
  end

  # Ensure the upload directory exists
  defp ensure_upload_dir do
    dir = Path.join(["priv", "static", "uploads", "events"])
    File.mkdir_p!(dir)
  end
end
