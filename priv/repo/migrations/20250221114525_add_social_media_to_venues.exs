defmodule TriviaAdvisor.Repo.Migrations.AddSocialMediaToVenues do
  use Ecto.Migration

  def change do
    alter table(:venues) do
      add :facebook, :string
      add :instagram, :string
    end
  end
end
