defmodule TriviaAdvisor.Repo.Migrations.CreatePerformers do
  use Ecto.Migration

  def change do
    create table(:performers) do
      add :name, :string, null: false
      add :profile_image_url, :string
      add :source_id, references(:sources), null: false

      timestamps()
    end

    # Index for faster lookups by name within a source
    create index(:performers, [:source_id, :name])

    # Add performer_id to events
    alter table(:events) do
      add :performer_id, references(:performers), null: true
    end
  end
end
