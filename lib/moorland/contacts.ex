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

defmodule Moorland.Contacts do
  @moduledoc """
  The production rolodex: cast, crew, and collaborators as people with roles
  and departments. Feeds call sheets and day-out-of-days in the production
  phase. Contacts belong to the user who created them.
  """

  import Ecto.Query, warn: false

  alias Moorland.Repo
  alias Moorland.Accounts.Scope
  alias Moorland.Contacts.Contact

  def list_contacts(%Scope{user: user}) do
    from(c in Contact, where: c.user_id == ^user.id, order_by: [asc: c.name])
    |> Repo.all()
  end

  def create_contact(%Scope{user: user}, attrs) do
    %Contact{user_id: user.id}
    |> Contact.changeset(attrs)
    |> Repo.insert()
  end

  def update_contact(%Scope{user: user}, id, attrs) do
    case Repo.get_by(Contact, id: id, user_id: user.id) do
      nil -> {:error, :not_found}
      contact -> contact |> Contact.changeset(attrs) |> Repo.update()
    end
  end

  def delete_contact(%Scope{user: user}, id) do
    case Repo.get_by(Contact, id: id, user_id: user.id) do
      nil -> {:error, :not_found}
      contact -> Repo.delete(contact)
    end
  end
end
