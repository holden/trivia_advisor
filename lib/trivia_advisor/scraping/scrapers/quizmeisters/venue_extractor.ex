defmodule TriviaAdvisor.Scraping.Scrapers.Quizmeisters.VenueExtractor do
  @moduledoc """
  Extracts venue data specifically from Quizmeisters HTML structure.
  """

  require Logger

  def extract_venue_data(document, url, _raw_title) do
    try do
      # Extract description from the venue-specific description first
      description = document
        |> Floki.find(".venue-description.w-richtext:not(.trivia-generic):not(.bingo-generic):not(.survey-generic) p")
        |> Enum.map(&Floki.text/1)
        |> Enum.join("\n\n")
        |> String.trim()
        |> filter_lorem_ipsum()

      # If no venue-specific description, get the trivia generic one
      description = if description == "",
        do: document
          |> Floki.find(".venue-description.trivia-generic.w-richtext p")
          |> Enum.map(&Floki.text/1)
          |> Enum.join("\n\n")
          |> String.trim()
          |> filter_lorem_ipsum(),
        else: description

      # Extract hero image
      hero_image_url = document
        |> Floki.find(".venue-photo")
        |> Floki.attribute("src")
        |> List.first()

      # Extract performer info
      performer = document
        |> Floki.find(".host-info")
        |> extract_performer_info()

      # Extract social links from the icon block
      social_links = document
        |> Floki.find(".icon-block a")
        |> Enum.reduce(%{website: nil, facebook: nil, instagram: nil}, fn el, acc ->
          href = Floki.attribute(el, "href") |> List.first()
          cond do
            Floki.find(el, "img[alt*='website']") |> Enum.any?() ->
              %{acc | website: href}
            Floki.find(el, "img[alt*='facebook']") |> Enum.any?() ->
              %{acc | facebook: href}
            Floki.find(el, "img[alt*='instagram']") |> Enum.any?() ->
              %{acc | instagram: href}
            true -> acc
          end
        end)

      # Extract phone from the venue block
      phone = document
        |> Floki.find(".venue-block .paragraph")
        |> Enum.map(&Floki.text/1)
        |> Enum.find(fn text ->
          String.match?(text, ~r/^\+?[\d\s-]{8,}$/)
        end)
        |> case do
          nil -> nil
          number -> String.trim(number)
        end

      # Check if venue is on break
      on_break = document
        |> Floki.find(".on-break")
        |> Enum.any?()

      {:ok, Map.merge(%{
        description: description,
        hero_image_url: hero_image_url,
        on_break: on_break,
        phone: phone,
        performer: performer
      }, social_links)}
    rescue
      e ->
        Logger.error("Failed to extract venue data from #{url}: #{Exception.message(e)}")
        {:error, "Failed to extract venue data: #{Exception.message(e)}"}
    end
  end

  defp extract_performer_info(host_info) do
    case host_info do
      [] -> nil
      elements ->
        name = elements
          |> Floki.find(".host-name")
          |> Floki.text()
          |> String.trim()

        # Find all host images
        images = elements
          |> Floki.find(".host-image")
          |> Enum.filter(fn img ->
            # Filter out placeholder images
            class = Floki.attribute(img, "class") |> List.first() || ""
            not String.contains?(class, "placeholder") and not String.contains?(class, "w-condition-invisible")
          end)

        # Get the src attribute of the first real image
        profile_image = case images do
          [] -> nil
          [img | _] -> Floki.attribute(img, "src") |> List.first()
        end

        if name != "" or profile_image do
          Logger.debug("✅ Found performer: #{name}, image: #{profile_image != nil}")
          %{
            name: name,
            profile_image: profile_image
          }
        else
          nil
        end
    end
  end

  defp filter_lorem_ipsum(text) when is_binary(text) do
    if String.starts_with?(text, "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore e"), do: "", else: text
  end
  defp filter_lorem_ipsum(_), do: ""
end
