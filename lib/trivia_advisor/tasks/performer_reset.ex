defmodule TriviaAdvisor.Tasks.PerformerReset do
  @moduledoc """
  Module for resetting performer data in production.
  This is a production-friendly version of Mix.Tasks.Performers.Reset.
  """
  require Logger
  import Ecto.Query

  @doc """
  Reset all performers data.

  Options:
    * `:keep_images` - Don't delete performer image directories (default: false)
    * `:dry_run` - Show what would be done without making changes (default: false)
  """
  def reset_all(opts \\ []) do
    # Parse options
    keep_images = Keyword.get(opts, :keep_images, false)
    dry_run = Keyword.get(opts, :dry_run, false)

    if dry_run do
      Logger.info("🔍 DRY RUN MODE - No changes will be made")
    end

    # 1. Get Quizmeisters source
    source_id = get_quizmeisters_source_id()

    # 2. Set performer_id to NULL for all Quizmeisters events
    clear_performer_ids(source_id, dry_run)

    # 3. Delete all performers
    delete_performers(dry_run)

    # 4. Delete performer image directories (unless --keep-images is specified)
    unless keep_images do
      delete_performer_images(dry_run)
    end

    Logger.info("✅ Performer reset completed successfully!")
    :ok
  end

  defp get_quizmeisters_source_id do
    case TriviaAdvisor.Repo.get_by(TriviaAdvisor.Scraping.Source, name: "quizmeisters") do
      nil ->
        Logger.error("❌ Quizmeisters source not found in the database")
        raise "Quizmeisters source not found"
      source ->
        Logger.info("📊 Found Quizmeisters source with ID: #{source.id}")
        source.id
    end
  end

  defp clear_performer_ids(source_id, dry_run) do
    # Find all events from the Quizmeisters source with non-nil performer_id
    query = from e in TriviaAdvisor.Events.Event,
            join: es in TriviaAdvisor.Events.EventSource,
            on: e.id == es.event_id,
            where: es.source_id == ^source_id and not is_nil(e.performer_id)

    # Count the affected events
    count = TriviaAdvisor.Repo.aggregate(query, :count, :id)
    Logger.info("🔄 Found #{count} Quizmeisters events with performer IDs")

    if count > 0 and not dry_run do
      # Update the events to set performer_id to nil
      {updated, _} = TriviaAdvisor.Repo.update_all(query, set: [performer_id: nil])
      Logger.info("✅ Removed performer IDs from #{updated} events")
    end
  end

  defp delete_performers(dry_run) do
    # Count the total number of performers
    count = TriviaAdvisor.Repo.aggregate(TriviaAdvisor.Events.Performer, :count, :id)
    Logger.info("🔄 Found #{count} performers to delete")

    if count > 0 and not dry_run do
      # Delete performers one by one to ensure before_delete callbacks are invoked
      performers = TriviaAdvisor.Repo.all(TriviaAdvisor.Events.Performer)

      deleted_count = Enum.reduce(performers, 0, fn performer, count ->
        case TriviaAdvisor.Repo.delete(performer) do
          {:ok, _} -> count + 1
          {:error, error} ->
            Logger.error("❌ Error deleting performer #{performer.id}: #{inspect(error)}")
            count
        end
      end)

      Logger.info("✅ Successfully deleted #{deleted_count}/#{count} performers")
    end
  end

  defp delete_performer_images(dry_run) do
    # Path to the performers image directory
    performers_dir = Path.join(["priv", "static", "uploads", "performers"])

    # Check if the directory exists
    if File.dir?(performers_dir) do
      # Count subdirectories (performer image folders)
      {dirs, _files} = File.ls!(performers_dir)
                      |> Enum.map(fn entry -> Path.join(performers_dir, entry) end)
                      |> Enum.split_with(&File.dir?/1)

      dir_count = length(dirs)

      Logger.info("🔄 Found #{dir_count} performer image directories to delete")

      if dir_count > 0 and not dry_run do
        # Delete the entire performers directory and recreate it
        File.rm_rf!(performers_dir)
        File.mkdir_p!(performers_dir)

        Logger.info("✅ Successfully deleted and recreated the performers image directory")
      end
    else
      Logger.info("ℹ️ No performers image directory found at #{performers_dir}")
      # Create the directory if it doesn't exist and we're not in dry run mode
      unless dry_run do
        File.mkdir_p!(performers_dir)
        Logger.info("✅ Created performers image directory")
      end
    end
  end
end
