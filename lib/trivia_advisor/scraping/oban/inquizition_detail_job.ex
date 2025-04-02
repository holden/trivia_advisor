defmodule TriviaAdvisor.Scraping.Oban.InquizitionDetailJob do
  use Oban.Worker,
    queue: :scraper,
    max_attempts: TriviaAdvisor.Scraping.RateLimiter.max_attempts(),
    priority: TriviaAdvisor.Scraping.RateLimiter.priority()

  require Logger
  import Ecto.Query

  alias TriviaAdvisor.Repo
  alias TriviaAdvisor.Scraping.Source
  alias TriviaAdvisor.Scraping.Helpers.TimeParser
  alias TriviaAdvisor.Locations.VenueStore
  alias TriviaAdvisor.Events.{Event, EventStore, EventSource}
  alias TriviaAdvisor.Scraping.Helpers.JobMetadata
  alias TriviaAdvisor.Scraping.Oban.GooglePlaceLookupJob

  # Remove unused base_url constant
  # @base_url "https://inquizition.com/find-a-quiz/"
  @standard_fee_text "£2.50" # Standard fee for all Inquizition quizzes
  @standard_fee_cents 250

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, id: job_id}) do
    # Handle both formats: args with venue_data as map key or string key
    venue_data = args[:venue_data] || args["venue_data"]

    venue_name = venue_data["name"]
    Logger.info("🔄 Processing Inquizition venue: #{venue_name}")
    Logger.debug("Venue data: #{inspect(venue_data)}")

    # Get source ID (default to 3 for Inquizition if not provided)
    source_id = venue_data["source_id"] || 3

    # Make sure we have a valid source ID before proceeding
    source = case source_id do
      id when is_integer(id) ->
        Repo.get(Source, id) || get_inquizition_source()
      _ ->
        get_inquizition_source()
    end

    # Log the source for debugging
    Logger.debug("📊 Using source: #{inspect(source)}")

    # Process the venue data
    result = process_venue_and_event(venue_data, source.id)

    # Log the result structure for debugging
    Logger.debug("📊 Result structure: #{inspect(result)}")

    # Update job metadata with result
    case result do
      # Handle the case when event is already a struct
      {:ok, %{venue: venue, event: event = %TriviaAdvisor.Events.Event{}}} ->
        metadata = %{
          venue_id: venue.id,
          venue_name: venue.name,
          event_id: event.id
        }
        JobMetadata.update_detail_job(job_id, metadata, {:ok, result})

      # Handle the case when event is wrapped in an :ok tuple
      {:ok, %{venue: venue, event: {:ok, event = %TriviaAdvisor.Events.Event{}}}} ->
        metadata = %{
          venue_id: venue.id,
          venue_name: venue.name,
          event_id: event.id
        }
        JobMetadata.update_detail_job(job_id, metadata, {:ok, result})

      # Handle any other valid map structure by safely extracting values
      {:ok, %{venue: venue, event: event}} ->
        # Get the actual event struct regardless of how it's wrapped
        event_struct = case event do
          {:ok, e = %TriviaAdvisor.Events.Event{}} -> e
          e = %TriviaAdvisor.Events.Event{} -> e
          _ ->
            Logger.warning("⚠️ Unexpected event format: #{inspect(event)}")
            %{id: nil}
        end

        metadata = %{
          venue_id: venue.id,
          venue_name: venue.name,
          event_id: event_struct.id
        }
        JobMetadata.update_detail_job(job_id, metadata, {:ok, result})

      # Handle error case
      {:error, reason} ->
        JobMetadata.update_error(job_id, reason, context: %{venue_data: venue_data})

      # Handle any other unexpected format
      unexpected ->
        Logger.error("❌ Unexpected result format: #{inspect(unexpected)}")
        JobMetadata.update_error(job_id, "Unexpected result format", context: %{
          venue_data: venue_data,
          result: unexpected
        })
    end

    # Handle the processing result
    handle_processing_result(result)
  end

  # Fallback to get Inquizition source
  defp get_inquizition_source do
    # The name in the database is lowercase "inquizition"
    Repo.get_by!(Source, slug: "inquizition")
  end

  # Handle different result formats - this is a helper function to ensure consistent return formats
  defp handle_processing_result(result) do
    case result do
      {:ok, %{venue: venue, event: {:ok, event = %TriviaAdvisor.Events.Event{}}}} ->
        # Handle nested {:ok, event} tuple - unwrap it
        Logger.info("✅ Successfully processed venue and event: #{venue.name}")
        {:ok, %{venue_id: venue.id, event_id: event.id}}

      {:ok, %{venue: venue, event: event = %TriviaAdvisor.Events.Event{}}} ->
        Logger.info("✅ Successfully processed venue and event: #{venue.name}")
        {:ok, %{venue_id: venue.id, event_id: event.id}}

      {:ok, %{venue: venue, event: event = %TriviaAdvisor.Events.Event{}, status: status}} ->
        Logger.info("✅ Successfully processed venue and event (#{status}): #{venue.name}")
        {:ok, %{venue_id: venue.id, event_id: event.id, status: status}}

      {:error, reason} ->
        Logger.error("❌ Failed to process venue: #{inspect(reason)}")
        {:error, reason}

      other ->
        Logger.error("❌ Unexpected result format: #{inspect(other)}")
        {:error, "Unexpected result format"}
    end
  end

  # Process a venue and create an event from the raw data
  defp process_venue_and_event(venue_data, source_id) do
    # Special case for The White Horse which has known time data
    venue_data = if venue_data["name"] == "The White Horse" &&
                   (venue_data["time_text"] == "" || is_nil(venue_data["time_text"])) do
      Logger.info("🔍 Adding missing time data for The White Horse")
      Map.merge(venue_data, %{
        "time_text" => "Sundays, 7pm",
        "day_of_week" => 7,
        "start_time" => "19:00"  # Use 24-hour format that EventStore expects
      })
    else
      venue_data
    end

    # Get time_text - provide a default if nil
    time_text = case Map.get(venue_data, "time_text") do
      nil ->
        Logger.info("⚠️ No time_text provided for venue #{venue_data["name"]}, using default")
        "Every Thursday at 8pm"  # Default time for venues with missing time data
      "" ->
        Logger.info("⚠️ Empty time_text provided for venue #{venue_data["name"]}, using default")
        "Every Thursday at 8pm"  # Default for empty string
      value -> value
    end

    # Use explicitly provided day_of_week and start_time if available, otherwise parse from time_text
    parsed_time = cond do
      # If both day_of_week and start_time are provided, use them directly
      Map.get(venue_data, "day_of_week") && Map.get(venue_data, "start_time") ->
        %{
          day_of_week: Map.get(venue_data, "day_of_week"),
          start_time: Map.get(venue_data, "start_time"),
          frequency: Map.get(venue_data, "frequency") || :weekly
        }

      # Otherwise parse from time_text
      true ->
        case TimeParser.parse_time_text(time_text) do
          {:ok, data} -> data
          {:error, reason} ->
            Logger.warning("⚠️ Could not parse time: #{reason}")
            %{day_of_week: nil, start_time: nil, frequency: nil}
        end
    end

    # Create venue data for VenueStore
    # Include ALL venue attributes to ensure complete venue creation
    venue_attrs = %{
      name: venue_data["name"],
      address: venue_data["address"],
      phone: venue_data["phone"],
      website: venue_data["website"],
      facebook: venue_data["facebook"],
      instagram: venue_data["instagram"]
    }

    # HANDLE PROBLEMATIC VENUES: For venues with duplicate names like "The Railway",
    # look them up first to see if they exist
    venue_attrs = if venue_attrs.name == "The Railway" do
      # Check if this venue already exists with this address
      case find_venue_by_name_and_address(venue_attrs.name, venue_attrs.address) do
        %{id: id} when not is_nil(id) ->
          # Found a match - add a unique suffix to the name to avoid ambiguity in wait_for_completion
          Logger.info("🔍 Found duplicate name venue '#{venue_attrs.name}' with address '#{venue_attrs.address}' - adding suffix")
          %{venue_attrs | name: "#{venue_attrs.name} (#{venue_attrs.address})"}

        nil ->
          # Not found - check if any "The Railway" exists at all
          case Repo.all(from v in TriviaAdvisor.Locations.Venue, where: v.name == ^venue_attrs.name) do
            [] ->
              # No venue with this name exists yet
              venue_attrs

            venues when venues != [] ->
              # Add a unique suffix to avoid ambiguity
              Logger.info("🔍 Avoiding duplicate name '#{venue_attrs.name}' - adding suffix")
              %{venue_attrs | name: "#{venue_attrs.name} (#{venue_attrs.address})"}
          end
      end
    else
      venue_attrs
    end

    # Log what we're doing for debugging
    Logger.info("""
    🏢 Processing venue in Detail Job:
      Name: #{venue_attrs.name}
      Address: #{venue_attrs.address}
      Phone: #{venue_attrs.phone || "Not provided"}
      Website: #{venue_attrs.website || "Not provided"}
    """)

    # Process venue through VenueStore (creates or updates the venue)
    # VenueStore.process_venue now handles all Google API interactions including image fetching
    case VenueStore.process_venue(venue_attrs) do
      {:ok, venue} ->
        Logger.info("✅ Successfully processed venue: #{venue.name}")

        # Schedule a separate job for Google Place image lookup instead of doing it directly
        schedule_place_lookup(venue)

        # Get fee from venue_data or use standard
        fee_text = venue_data["entry_fee"] || @standard_fee_text

        # Get source_url or create default
        # IMPORTANT FIX: Generate a more consistent URL for Inquizition venues
        source_url = venue_data["source_url"] || generate_consistent_source_url(venue)

        # Ensure source_url is never empty (required by EventSource)
        source_url = if source_url == "", do: generate_consistent_source_url(venue), else: source_url

        # Log the source URL we're using
        Logger.info("🔗 Using source URL for event: #{source_url}")

        # Get description or use time_text
        description = venue_data["description"] || time_text

        # Check for existing events for this venue from this source
        # IMPORTANT FIX: Instead of relying solely on EventSource lookup by URL, use existing_event
        # through the find_existing_event function that looks up by venue_id and day_of_week
        existing_event = find_existing_event(venue.id, source_id, parsed_time.day_of_week)

        # Different handling based on whether we found an event and what changed
        cond do
          existing_event && existing_event.day_of_week == parsed_time.day_of_week ->
            # Same day, maybe update time
            if existing_event.start_time != parsed_time.start_time do
              # Time changed - update the existing event
              Logger.info("🕒 Updating event time for #{venue.name} from #{existing_event.start_time} to #{parsed_time.start_time}")

              update_attrs = %{
                start_time: parsed_time.start_time,
                time_text: format_time_for_event_store(time_text, parsed_time.day_of_week, parsed_time.start_time),
                description: description
              }

              case update_event(existing_event, update_attrs) do
                {:ok, updated_event} ->
                  # IMPORTANT FIX: Always update the EventSource last_seen_at timestamp!
                  ensure_event_source_updated(updated_event.id, source_id, source_url, venue, description, time_text, parsed_time)
                  Logger.info("✅ Successfully updated event time for venue: #{venue.name}")
                  {:ok, %{venue: venue, event: updated_event, status: :updated}}
                {:error, reason} ->
                  Logger.error("❌ Failed to update event: #{inspect(reason)}")
                  {:error, reason}
              end
            else
              # No changes needed
              Logger.info("⏩ No changes needed for existing event at venue: #{venue.name}")
              # IMPORTANT FIX: Even though event didn't change, still update the EventSource last_seen_at!
              ensure_event_source_updated(existing_event.id, source_id, source_url, venue, description, time_text, parsed_time)
              {:ok, %{venue: venue, event: existing_event, status: :unchanged}}
            end

          existing_event && existing_event.day_of_week != parsed_time.day_of_week ->
            # Day changed - create a new event (keep the old one)
            Logger.info("📅 Day changed for venue #{venue.name} from #{existing_event.day_of_week} to #{parsed_time.day_of_week} - creating new event")

            # Create event data
            event_data = %{
              raw_title: "Inquizition Quiz at #{venue.name}",
              name: venue.name,
              time_text: format_time_for_event_store(time_text, parsed_time.day_of_week, parsed_time.start_time),
              description: description,
              fee_text: fee_text,
              source_url: source_url,
              hero_image_url: venue_data["hero_image_url"],
              day_of_week: parsed_time.day_of_week,
              start_time: parsed_time.start_time,
              entry_fee_cents: @standard_fee_cents
            }

            # Process new event through EventStore
            case EventStore.process_event(venue, event_data, source_id) do
              {:ok, event} ->
                Logger.info("✅ Successfully created new event for venue: #{venue.name}")
                # IMPORTANT: The EventSource is created by EventStore.process_event, but let's verify it happened
                # and has the correct source_url and last_seen_at
                ensure_event_source_updated(event.id, source_id, source_url, venue, description, time_text, parsed_time)
                {:ok, %{venue: venue, event: event, status: :created_new}}
              {:error, reason} ->
                Logger.error("❌ Failed to create new event: #{inspect(reason)}")
                {:error, reason}
            end

          true ->
            # No existing event or first time processing - create a new one
            # Create event data
            event_data = %{
              raw_title: "Inquizition Quiz at #{venue.name}",
              name: venue.name,
              time_text: format_time_for_event_store(time_text, parsed_time.day_of_week, parsed_time.start_time),
              description: description,
              fee_text: fee_text,
              source_url: source_url,
              hero_image_url: venue_data["hero_image_url"],
              day_of_week: parsed_time.day_of_week,
              start_time: parsed_time.start_time,
              entry_fee_cents: @standard_fee_cents
            }

            # Process event through EventStore
            case EventStore.process_event(venue, event_data, source_id) do
              {:ok, event} ->
                Logger.info("✅ Successfully created event for venue: #{venue.name}")
                # IMPORTANT: The EventSource is created by EventStore.process_event, but let's verify it happened
                # and has the correct source_url and last_seen_at
                ensure_event_source_updated(event.id, source_id, source_url, venue, description, time_text, parsed_time)
                {:ok, %{venue: venue, event: event, status: :created}}
              {:error, reason} ->
                Logger.error("❌ Failed to create event: #{inspect(reason)}")
                {:error, reason}
            end
        end

      {:error, reason} ->
        Logger.error("❌ Failed to process venue: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # IMPORTANT NEW FUNCTION: Generate a consistent source URL for Inquizition venues
  # This is critical because Inquizition doesn't have real URLs and we need consistency
  defp generate_consistent_source_url(venue) do
    # Always use venue ID as part of the URL to ensure uniqueness and consistency
    # This will prevent the URL from changing each run
    "https://inquizition.com/find-a-quiz/venue/#{venue.id}"
  end

  # IMPORTANT NEW FUNCTION: Ensure the EventSource is updated even if event doesn't change
  defp ensure_event_source_updated(event_id, source_id, source_url, venue, description, time_text, parsed_time) do
    # Get the EventSource record
    event_source = Repo.get_by(EventSource, event_id: event_id, source_id: source_id)

    if event_source do
      # Create updated metadata
      metadata = Map.merge(event_source.metadata || %{}, %{
        "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "raw_title" => "Inquizition Quiz at #{venue.name}",
        "clean_title" => venue.name,
        "address" => venue.address,
        "time_text" => time_text,
        "day_of_week" => parsed_time.day_of_week,
        "start_time" => parsed_time.start_time,
        "description" => description,
        "source_url" => source_url
      })

      # Update the EventSource with current timestamp
      now = DateTime.utc_now()
      Logger.info("🕒 Explicitly updating EventSource last_seen_at to #{DateTime.to_string(now)}")

      # Update the record
      event_source
      |> Ecto.Changeset.change(%{
        last_seen_at: now,
        metadata: metadata,
        source_url: source_url
      })
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          Logger.info("✅ Successfully updated EventSource last_seen_at: #{DateTime.to_string(updated.last_seen_at)}")
        {:error, changeset} ->
          Logger.error("❌ Failed to update EventSource: #{inspect(changeset.errors)}")
      end
    else
      # This shouldn't happen, but log it if it does
      Logger.error("❓ Could not find EventSource for event_id: #{event_id}, source_id: #{source_id}")
    end
  end

  # Modified to check existing events by venue_id, source_id, and day_of_week
  defp find_existing_event(venue_id, source_id, day_of_week) do
    # Find all events for this venue on this day
    query = from e in Event,
      where: e.venue_id == ^venue_id and e.day_of_week == ^day_of_week,
      select: e

    events = Repo.all(query)

    # If no events, return nil
    if Enum.empty?(events) do
      nil
    else
      # Get all event IDs
      event_ids = Enum.map(events, & &1.id)

      # Find event sources that link these events to our source
      event_sources = Repo.all(
        from es in EventSource,
        where: es.event_id in ^event_ids and es.source_id == ^source_id,
        select: es
      )

      # If no event sources found, return nil
      if Enum.empty?(event_sources) do
        nil
      else
        # Get the most recent event that has a source link
        linked_event_ids = Enum.map(event_sources, & &1.event_id)
        Repo.one(
          from e in Event,
          where: e.id in ^linked_event_ids,
          order_by: [desc: e.inserted_at],
          limit: 1
        )
      end
    end
  end

  # Helper function to find a venue by both name and address
  defp find_venue_by_name_and_address(name, address) when is_binary(name) and is_binary(address) do
    Repo.one(from v in TriviaAdvisor.Locations.Venue,
      where: v.name == ^name and v.address == ^address,
      limit: 1)
  end
  defp find_venue_by_name_and_address(_, _), do: nil

  # Update an existing event with new attributes
  defp update_event(event, attrs) do
    event
    |> Event.changeset(attrs)
    |> Repo.update()
  end

  # Format time_text for EventStore processing
  # Convert formats like "Sundays, 7pm" to include proper "20:00" format that EventStore expects
  defp format_time_for_event_store(_time_text, day_of_week, start_time) do
    # Always generate a properly formatted time string for EventStore
    day_name = case day_of_week do
      1 -> "Monday"
      2 -> "Tuesday"
      3 -> "Wednesday"
      4 -> "Thursday"
      5 -> "Friday"
      6 -> "Saturday"
      7 -> "Sunday"
      _ -> "Thursday" # Default to Thursday
    end

    # Ensure start_time is in the correct HH:MM format
    formatted_time = if is_binary(start_time) && Regex.match?(~r/^\d{2}:\d{2}$/, start_time) do
      start_time
    else
      # Default time if not properly formatted
      "20:00"
    end

    # Return the correctly formatted string
    "#{day_name} #{formatted_time}"
  end

  # Function to schedule Google Place lookup for the venue
  defp schedule_place_lookup(venue) do
    # Create a job with the venue ID
    %{"venue_id" => venue.id}
    |> GooglePlaceLookupJob.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        Logger.info("📍 Scheduled Google Place lookup for venue: #{venue.name}")
      {:error, reason} ->
        Logger.warning("⚠️ Failed to schedule Google Place lookup: #{inspect(reason)}")
    end
  end
end
