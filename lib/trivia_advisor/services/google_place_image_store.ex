defmodule TriviaAdvisor.Services.GooglePlaceImageStore do
  @moduledoc """
  Service for downloading, storing, and managing Google Place images for venues.
  This service:
  1. Downloads images from Google Places API
  2. Stores them physically using Waffle
  3. Updates the venue's google_place_images field with metadata
  """

  use GenServer
  require Logger
  alias TriviaAdvisor.Repo
  alias TriviaAdvisor.Locations.Venue
  alias TriviaAdvisor.Uploaders.GooglePlaceImage
  alias TriviaAdvisor.Services.GooglePlacesService

  @max_images 5
  @refresh_days 90  # Number of days before considering refreshing venue images
  @http_client Application.compile_env(:trivia_advisor, :http_client, HTTPoison)

  # Client API

  @doc """
  Start the GooglePlaceImageStore service
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Smart function to check if a venue should have its Google Place images updated
  and update them if needed. This is intended to be used by scrapers.

  It will only update images if:
  1. The venue has a place_id, and
  2. One of the following is true:
     a. The venue has no google_place_images
     b. The venue has fewer than 5 google_place_images
     c. The venue's images haven't been updated in at least 90 days

  Returns the venue (updated if images were fetched, or original if not)
  """
  def maybe_update_venue_images(venue) do
    if should_update_images?(venue) do
      Logger.info("🖼️ Fetching Google Place images for venue: #{venue.name}")

      try do
        case process_venue_images(venue) do
          {:ok, updated_venue} ->
            Logger.info("✅ Successfully fetched Google Place images for venue: #{venue.name}")
            updated_venue
          {:error, _reason} ->
            # Return the original venue on error
            venue
        end
      rescue
        e ->
          Logger.error("❌ Error fetching Google Place images: #{Exception.message(e)}")
          venue
      end
    else
      # Logger.debug("⏭️ Skipping Google Place images for venue: #{venue.name}")
      venue
    end
  end

  @doc """
  Determines if a venue should have its Google Place images updated
  based on defined criteria.
  """
  def should_update_images?(venue) do
    has_place_id?(venue) && (
      missing_or_few_images?(venue) ||
      images_need_refresh?(venue)
    )
  end

  @doc """
  Checks if a venue has a valid place_id.
  """
  def has_place_id?(venue) do
    Map.get(venue, :place_id) && venue.place_id != ""
  end

  @doc """
  Checks if a venue is missing images or has fewer than the max number.
  """
  def missing_or_few_images?(venue) do
    images = Map.get(venue, :google_place_images, [])
    is_nil(images) || length(images) < @max_images
  end

  @doc """
  Checks if a venue's images need to be refreshed based on the
  last update timestamp.
  """
  def images_need_refresh?(venue) do
    updated_at = Map.get(venue, :updated_at)

    if is_nil(updated_at) do
      true
    else
      days_since_update = DateTime.diff(DateTime.utc_now(), updated_at, :second) / 86400
      days_since_update > @refresh_days
    end
  end

  @doc """
  Processes Google Place images for a venue:
  1. Fetches images from Google Places API
  2. Downloads and stores them physically
  3. Updates the venue's google_place_images field with metadata

  Returns {:ok, venue} or {:error, reason}
  """
  def process_venue_images(venue_id) when is_integer(venue_id) or is_binary(venue_id) do
    venue = Repo.get(Venue, venue_id)
    if venue, do: process_venue_images(venue), else: {:error, :venue_not_found}
  end

  def process_venue_images(%Venue{} = venue) do
    # Skip if no place_id
    if venue.place_id && venue.place_id != "" do
      # Get images from Google Places API
      case GooglePlacesService.get_venue_images(venue.id) do
        [] ->
          Logger.info("No Google Place images found for venue #{venue.id}")
          {:ok, venue}

        images when is_list(images) ->
          # Process images (download, store, update venue)
          case process_image_list(venue, images) do
            {:ok, updated_venue} ->
              {:ok, updated_venue}

            # If image processing fails, at least store the image URLs
            {:error, _reason} ->
              Logger.info("Storing image URLs instead of downloaded images for venue #{venue.id}")
              store_image_urls_in_venue(venue, images)
          end

        _ ->
          {:error, :invalid_images}
      end
    else
      {:ok, venue}
    end
  end

  @doc """
  Returns the URLs for stored Google Place images for a venue.

  Limits to the specified count (default 3), and orders by position.
  """
  def get_image_urls(venue, count \\ 3) do
    venue = ensure_loaded(venue)

    venue.google_place_images
    |> Enum.sort_by(& &1["position"], :asc)
    |> Enum.take(count)
    |> Enum.map(fn image_data ->
      # Prefer local URL if available
      if image_data["local_path"] do
        ensure_full_url(image_data["local_path"])
      else
        image_data["original_url"]
      end
    end)
  end

  @doc """
  Returns the first Google Place image URL for a venue, or nil if none exist.
  """
  def get_first_image_url(venue) do
    case get_image_urls(venue, 1) do
      [url | _] -> url
      _ -> nil
    end
  end

  @doc """
  Refreshes all venue Google Place images for maintenance purposes.

  Takes a limit parameter to control batch size.
  """
  def refresh_all_venue_images(max_venues \\ 100) do
    # Use a simpler approach without Ecto.Query macros for now
    venues = Repo.all("SELECT * FROM venues WHERE place_id IS NOT NULL AND place_id != '' LIMIT $1", [max_venues])

    {successful, failed} =
      venues
      |> Enum.map(fn venue ->
        case process_venue_images(venue) do
          {:ok, _} -> {:ok, venue.id}
          error -> {venue.id, error}
        end
      end)
      |> Enum.split_with(fn
        {:ok, _} -> true
        _ -> false
      end)

    %{
      processed: length(venues),
      successful: length(successful),
      failed: length(failed),
      failed_ids: Enum.map(failed, fn {id, _} -> id end)
    }
  end

  @doc """
  Deletes all Google Place images for a venue from the filesystem.
  This function is meant to be called from a before_delete callback.

  Returns :ok on success, or {:error, reason} on failure.
  """
  def delete_venue_images(%Venue{google_place_images: images, slug: slug} = venue) when is_list(images) and length(images) > 0 do
    Logger.info("🗑️ Deleting Google Place images for venue: #{venue.name}")

    # Track successes
    Enum.each(images, fn image ->
      position = image["position"] || 0
      # Create the scope that matches what was used when storing
      scope = {venue.id, slug, position}

      # We need to try to delete both the original and thumb versions
      versions = [:original, :thumb]

      Enum.each(versions, fn version ->
        # Generate filename using same pattern as in the uploader
        filename = "#{version}_google_place_#{position}.jpg"

        # Try to delete the file using Waffle
        # Instead of using Waffle.Actions.Delete.delete, we'll use a different approach
        # that's more robust for this specific case
        try do
          # Create a definition for deleting
          GooglePlaceImage = TriviaAdvisor.Uploaders.GooglePlaceImage

          # Delete the file directly
          :ok = GooglePlaceImage.delete({filename, scope})

          # Log the result
          Logger.debug("✅ Deleted image: #{filename}")
        rescue
          e ->
            Logger.warning("⚠️ Failed to delete image #{filename}: #{inspect(e)}")
        end
      end)
    end)

    Logger.info("✅ Successfully deleted all Google Place images for venue: #{venue.name}")
    :ok
  end

  # No images to delete
  def delete_venue_images(_venue), do: :ok

  # Server callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting GooglePlaceImageStore")
    {:ok, %{}}
  end

  # Private functions

  defp process_image_list(venue, image_urls) do
    # Limit to max images
    image_urls = Enum.take(image_urls, @max_images)

    # Download and process each image
    image_results =
      image_urls
      |> Enum.with_index(1)
      |> Enum.map(fn {url, position} ->
        process_single_image(venue, url, position)
      end)
      |> Enum.reject(fn
        {:error, _} -> true
        _ -> false
      end)

    # Update venue with new image data or return error if all failed
    if Enum.any?(image_results) do
      update_venue_with_images(venue, image_results)
    else
      {:error, :all_images_failed}
    end
  end

  defp process_single_image(venue, url, position) do
    photo_ref = extract_photo_reference(url)

    if photo_ref do
      case download_image(url) do
        {:ok, image_file} ->
          # Store image using Waffle
          scope = %{venue_id: venue.id, venue_slug: venue.slug, position: position}

          case upload_image(image_file, scope) do
            {:ok, filename} ->
              # Return successful image data
              %{
                "google_ref" => photo_ref,
                "original_url" => url,
                "local_path" => filename,
                "fetched_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
                "position" => position
              }

            {:error, reason} ->
              Logger.error("Failed to upload Google Place image: #{inspect(reason)}")
              {:error, :upload_failed}
          end

        {:error, reason} ->
          Logger.error("Failed to download Google Place image: #{inspect(reason)}")
          {:error, :download_failed}
      end
    else
      {:error, :invalid_url}
    end
  end

  defp update_venue_with_images(venue, image_data) when is_list(image_data) do
    if Enum.any?(image_data) do
      # Update venue with new image data
      venue
      |> Venue.changeset(%{google_place_images: image_data})
      |> Repo.update()
    else
      # No images to update
      {:ok, venue}
    end
  end

  defp download_image(url) do
    Logger.debug("Downloading Google Place image: #{url}")

    headers = [
      {"User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"},
      {"Accept", "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"},
      {"Referer", "https://www.google.com/"}
    ]

    # If the URL is from the Places API v2 (contains places.googleapis.com/v1),
    # then use the API key in the URL rather than adding it to the headers
    {url_for_request, headers_for_request, options} =
      if String.contains?(url, "places.googleapis.com/v1") do
        # Keep the key in the URL and use the right options for the new API
        {url, headers, [follow_redirect: true, recv_timeout: 15000]}
      else
        # For the old API, keep using the existing approach
        {url, headers, [follow_redirect: true, recv_timeout: 15000]}
      end

    case @http_client.get(url_for_request, headers_for_request, options) do
      {:ok, %{status_code: 200, body: body}} ->
        # Create temp file
        filename = "google_place_#{:crypto.strong_rand_bytes(8) |> Base.encode16()}.jpg"
        temp_path = Path.join(System.tmp_dir!(), filename)

        with :ok <- File.write(temp_path, body) do
          {:ok, %{path: temp_path, file_name: filename, content_type: "image/jpeg"}}
        else
          error ->
            Logger.error("Failed to write Google Place image to disk: #{inspect(error)}")
            {:error, :file_write_failed}
        end

      {:ok, response} ->
        Logger.error("Failed to download Google Place image, status code: #{response.status_code}")
        {:error, "HTTP error: #{response.status_code}"}

      {:error, reason} ->
        Logger.error("HTTP request error when downloading Google Place image: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp upload_image(image_file, scope) do
    try do
      # Convert image_file to Plug.Upload format that Waffle expects
      upload = if is_map(image_file) and Map.has_key?(image_file, :path) do
        # Already in the right format
        %Plug.Upload{
          path: image_file.path,
          filename: image_file.file_name,
          content_type: image_file.content_type
        }
      else
        # Convert to expected format
        %Plug.Upload{
          path: image_file[:path] || image_file["path"],
          filename: image_file[:file_name] || image_file["file_name"],
          content_type: image_file[:content_type] || image_file["content_type"] || "image/jpeg"
        }
      end

      case GooglePlaceImage.store({upload, scope}) do
        {:ok, filename} ->
          path = GooglePlaceImage.url({filename, scope}, :original)
          # Strip the /priv/static prefix if it exists
          path = String.replace(path, ~r{^/priv/static}, "")
          {:ok, path}

        error ->
          Logger.error("Waffle upload failed: #{inspect(error)}")
          {:error, error}
      end
    rescue
      e ->
        Logger.error("Exception during image upload: #{inspect(e)}")
        {:error, :upload_exception}
    end
  end

  defp extract_photo_reference(url) do
    cond do
      # For Google Maps CDN URL format (PhotoService.GetPhoto)
      String.contains?(url, "PhotoService.GetPhoto") ->
        case Regex.run(~r/1s([^&]+)/, url) do
          [_, photo_id] -> photo_id
          _ -> nil
        end

      # For new Places API v2 URL format (photos/:getFullSizeImage)
      String.contains?(url, "photos:getFullSizeImage") ->
        case Regex.run(~r/photoreference=([^&]+)/, url) do
          [_, photo_ref] -> photo_ref
          _ -> nil
        end

      # For new Places API v2 URL format (places/{place_id}/photos/{photo_id})
      String.contains?(url, "/places/") && String.contains?(url, "/photos/") ->
        case Regex.run(~r{/places/[^/]+/photos/([^/?]+)}, url) do
          [_, photo_id] -> photo_id
          _ -> nil
        end

      # For old API format
      true ->
        case Regex.run(~r/photoreference=([^&]+)/, url) do
          [_, photo_ref] -> photo_ref
          _ -> nil
        end
    end
  end

  defp ensure_loaded(%Venue{google_place_images: images} = venue) when is_list(images), do: venue
  defp ensure_loaded(%Venue{} = venue), do: Repo.reload(venue)
  defp ensure_loaded(venue_id) when is_integer(venue_id) or is_binary(venue_id) do
    Repo.get(Venue, venue_id)
  end

  defp ensure_full_url(path) do
    if String.starts_with?(path, "http") do
      path
    else
      # Add the static path prefix if needed
      if String.starts_with?(path, "/") do
        path
      else
        "/#{path}"
      end
    end
  end

  # Store original image URLs in the venue's google_place_images field
  defp store_image_urls_in_venue(venue, image_urls) do
    image_data = Enum.with_index(image_urls, 1)
      |> Enum.map(fn {url, position} ->
        %{
          "original_url" => url,
          "fetched_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "position" => position
        }
      end)

    # Update venue with new image data
    venue
    |> Venue.changeset(%{google_place_images: image_data})
    |> Repo.update()
  end
end
