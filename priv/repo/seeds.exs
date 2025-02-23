# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     TriviaAdvisor.Repo.insert!(%TriviaAdvisor.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias TriviaAdvisor.Scraping.Source
alias TriviaAdvisor.Repo

sources = [
  %{
    name: "question one",
    website_url: "https://questionone.com"
  },
  %{
    name: "geeks who drink",
    website_url: "https://www.geekswhodrink.com"
  },
  %{
    name: "inquizition",
    website_url: "https://inquizition.com"
  },
  %{
    name: "quizmeisters",
    website_url: "https://quizmeisters.com"
  }
]

Enum.each(sources, fn source_params ->
  %Source{}
  |> Source.changeset(source_params)
  |> Repo.insert!(on_conflict: :nothing)
end)
