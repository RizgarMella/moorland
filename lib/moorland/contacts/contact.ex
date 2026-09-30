defmodule Moorland.Contacts.Contact do
  use Ecto.Schema
  import Ecto.Changeset

  schema "contacts" do
    field :name, :string
    field :role, :string
    field :department, :string
    field :email, :string
    field :phone, :string
    field :notes, :string

    belongs_to :user, Moorland.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(contact, attrs) do
    contact
    |> cast(attrs, [:name, :role, :department, :email, :phone, :notes])
    |> validate_required([:name])
    |> validate_length(:name, max: 120)
    |> validate_length(:notes, max: 5000)
  end
end
