defmodule TriviaAdvisor.Events.Performer do
  use Ecto.Schema
  import Ecto.Changeset
  alias TriviaAdvisor.Events.Event
  alias TriviaAdvisor.Scraping.Source

  schema "performers" do
    field :name, :string
    field :profile_image_url, :string

    belongs_to :source, Source
    has_many :events, Event

    timestamps()
  end

  @doc false
  def changeset(performer, attrs) do
    performer
    |> cast(attrs, [:name, :profile_image_url, :source_id])
    |> validate_required([:name, :source_id])
    |> foreign_key_constraint(:source_id)
  end

  @doc """
  Finds or creates a performer by name and source_id.
  Updates the profile image if it has changed.
  """
  def find_or_create(attrs = %{name: name, source_id: source_id}) do
    case TriviaAdvisor.Repo.get_by(__MODULE__, name: name, source_id: source_id) do
      nil -> %__MODULE__{}
      performer -> performer
    end
    |> changeset(attrs)
    |> TriviaAdvisor.Repo.insert_or_update()
  end
end
