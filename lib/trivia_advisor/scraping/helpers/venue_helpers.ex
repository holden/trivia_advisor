defmodule TriviaAdvisor.Scraping.Helpers.VenueHelpers do
  @moduledoc """
  Generic helper functions for venue data extraction across different scrapers.
  """

  require Logger
  alias TriviaAdvisor.Scraping.Helpers.TimeParser

  @doc """
  Parses day of week from time text into integer (1-7, Monday-Sunday).
  """
  def parse_day_of_week(time_text) do
    case TimeParser.parse_day_of_week(time_text) do
      {:ok, day} -> day
      {:error, reason} -> raise reason
    end
  end

  @doc """
  Parses time string into Time struct.
  """
  def parse_time(time_text) do
    case TimeParser.parse_time(time_text) do
      {:ok, time_str} -> Time.from_iso8601!(time_str <> ":00")
      {:error, reason} -> raise reason
    end
  end

  @doc """
  Downloads an image from a URL and saves it to a temporary file.
  Returns {:ok, %{path: path, file_name: name}} or {:error, reason}
  """
  def download_image(nil), do: {:error, :no_image}
  def download_image(url) do
    case HTTPoison.get(url) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        tmp_path = Path.join(System.tmp_dir!(), "#{:crypto.strong_rand_bytes(16) |> Base.encode16()}")
        File.write!(tmp_path, body)
        {:ok, %{
          path: tmp_path,
          file_name: Path.basename(url)
        }}
      _ ->
        {:error, :download_failed}
    end
  end

  @doc """
  Logs extracted venue details in a consistent format.
  """
  def log_venue_details(venue) do
    # Base fields that are always logged
    base_fields = [
      {"Title (Raw)   ", venue.raw_title},
      {"Title (Clean) ", venue.title},
      {"Address       ", venue.address},
      {"Time Text     ", venue.time_text},
      {"Day of Week   ", venue.day_of_week},
      {"Start Time    ", venue.start_time},
      {"Frequency     ", venue.frequency},
      {"Fee          ", venue.fee_text},
      {"Phone        ", venue.phone || "Not provided"},
      {"Website      ", venue.website || "Not provided"},
      {"Description  ", String.slice(venue.description || "", 0..100) <> "..."},
      {"Hero Image   ", venue.hero_image_url || "Not provided"},
      {"Source URL   ", venue.url}
    ]

    # Add social media fields only if they exist in the venue map
    social_fields = []
    social_fields = if Map.has_key?(venue, :facebook), do: social_fields ++ [{"Facebook     ", venue.facebook || "Not provided"}], else: social_fields
    social_fields = if Map.has_key?(venue, :instagram), do: social_fields ++ [{"Instagram    ", venue.instagram || "Not provided"}], else: social_fields

    # Combine all fields and format them
    (base_fields ++ social_fields)
    |> Enum.map(fn {label, value} -> "  #{label}: #{inspect(value)}" end)
    |> Enum.join("\n")
    |> (fn text -> "📍 Extracted Venue Details:\n" <> text end).()
    |> Logger.info()
  end
end
