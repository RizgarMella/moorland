defmodule Moorland.Scripts.MentionNotifier do
  @moduledoc "Emails a collaborator when a comment @mentions them."

  import Swoosh.Email

  alias Moorland.Mailer

  def deliver(nil, _script, _comment), do: :ok

  def deliver(user, script, comment) do
    email =
      new()
      |> to(user.email)
      |> from({"Moorland", "moorland@localhost"})
      |> subject("You were mentioned in \"#{script.title}\"")
      |> text_body("""
      You were mentioned in a comment on "#{script.title}":

        #{String.slice(comment.body || "", 0, 500)}

      Open the script and its Comments panel to reply.
      """)

    Mailer.deliver(email)
    :ok
  rescue
    _ -> :ok
  end
end
