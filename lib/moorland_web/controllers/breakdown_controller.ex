defmodule MoorlandWeb.BreakdownController do
  use MoorlandWeb, :controller

  alias Moorland.Scripts
  alias Moorland.Scripts.Breakdown

  def csv(conn, %{"id" => id}) do
    {script, _role} = Scripts.get_script!(conn.assigns.current_scope, id)
    breakdown = Breakdown.build(script.content, Scripts.list_breakdown_tags(script))

    send_download(conn, {:binary, IO.iodata_to_binary(Breakdown.to_csv(breakdown))},
      filename: "#{filename(script.title)} - breakdown.csv",
      content_type: "text/csv"
    )
  end

  defp filename(title) do
    case title |> String.replace(~r/[^\p{L}\p{N} _.-]+/u, "") |> String.trim() do
      "" -> "script"
      name -> name
    end
  end
end
