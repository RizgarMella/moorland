defmodule Moorland.Scripts.Snippet do
  use Ecto.Schema
  import Ecto.Changeset

  schema "snippets" do
    field :body, :string

    belongs_to :user, Moorland.Accounts.User
    belongs_to :script, Moorland.Scripts.Script

    timestamps(type: :utc_datetime)
  end

  def changeset(snippet, attrs) do
    snippet
    |> cast(attrs, [:body, :script_id])
    |> validate_required([:body])
    |> validate_length(:body, max: 20_000)
  end
end
