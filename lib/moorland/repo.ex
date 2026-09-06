defmodule Moorland.Repo do
  use Ecto.Repo,
    otp_app: :moorland,
    adapter: Ecto.Adapters.SQLite3
end
