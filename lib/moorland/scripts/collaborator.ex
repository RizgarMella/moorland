defmodule Moorland.Scripts.Collaborator do
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(editor commenter viewer)

  schema "script_collaborators" do
    field :role, :string, default: "editor"

    belongs_to :script, Moorland.Scripts.Script
    belongs_to :user, Moorland.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles

  def changeset(collaborator, attrs) do
    collaborator
    |> cast(attrs, [:role, :user_id, :script_id])
    |> validate_required([:role, :user_id, :script_id])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:script_id, :user_id])
  end
end
