defmodule Moorland.Scripts.MediaItem do
  @moduledoc """
  A reference file in a production's media library: a location photo, a
  costume reference, a lookbook PDF, a temp track. The file lives in the
  data folder (`Storage.media_dir/<script id>/<file>`); `board` pins it to
  a named mood board.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @types %{
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".png" => "image/png",
    ".webp" => "image/webp",
    ".gif" => "image/gif",
    ".pdf" => "application/pdf",
    ".mp3" => "audio/mpeg",
    ".m4a" => "audio/mp4",
    ".wav" => "audio/wav",
    ".ogg" => "audio/ogg",
    ".mp4" => "video/mp4",
    ".webm" => "video/webm",
    ".mov" => "video/quicktime"
  }

  # Stored names: unique per upload, so a name a mirror lacks is a new file.
  @file_re ~r/\Amedia-[A-Za-z0-9-]+\.(jpg|jpeg|png|webp|gif|pdf|mp3|m4a|wav|ogg|mp4|webm|mov)\z/

  schema "media_items" do
    field :file, :string
    field :filename, :string, default: ""
    field :title, :string, default: ""
    field :caption, :string, default: ""
    field :board, :string, default: ""
    field :size, :integer, default: 0

    # Peer sync (see Comment).
    field :uid, :string, autogenerate: {Ecto.UUID, :generate, []}
    field :remote_author, :string
    field :peer_key, :binary
    field :rev, :integer, default: 1
    field :synced_rev, :integer, default: 0

    belongs_to :script, Moorland.Scripts.Script
    belongs_to :author, Moorland.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def types, do: @types
  def extensions, do: Map.keys(@types)
  def content_type(name), do: Map.get(@types, String.downcase(Path.extname(name || "")))
  def valid_file?(name), do: is_binary(name) and Regex.match?(@file_re, name)

  @doc "image | pdf | audio | video, from the stored name."
  def kind(%__MODULE__{file: file}), do: kind(file)

  def kind(name) when is_binary(name) do
    case content_type(name) do
      "image/" <> _ -> "image"
      "audio/" <> _ -> "audio"
      "video/" <> _ -> "video"
      "application/pdf" -> "pdf"
      _ -> "file"
    end
  end

  def kind(_), do: "file"

  def label(%__MODULE__{title: title, filename: filename}) do
    if String.trim(title || "") != "", do: title, else: filename
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:title, :caption, :board, :filename], empty_values: [])
    |> blank_nils([:title, :caption, :board, :filename])
    |> update_change(:board, &String.trim/1)
    |> update_change(:title, &String.trim/1)
    |> validate_length(:title, max: 200)
    |> validate_length(:caption, max: 2000)
    |> validate_length(:board, max: 80)
    |> validate_length(:filename, max: 255)
  end

  defp blank_nils(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, cs ->
      if get_change(cs, field, :none) == nil, do: put_change(cs, field, ""), else: cs
    end)
  end
end
