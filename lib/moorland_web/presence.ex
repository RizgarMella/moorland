defmodule MoorlandWeb.Presence do
  use Phoenix.Presence,
    otp_app: :moorland,
    pubsub_server: Moorland.PubSub
end
