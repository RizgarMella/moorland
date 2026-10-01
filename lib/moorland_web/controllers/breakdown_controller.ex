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

  @doc "A prose document as Word (standard manuscript) or EPUB."
  def prose(conn, %{"id" => id, "format" => format}) when format in ["docx", "epub"] do
    scope = conn.assigns.current_scope
    {script, _role} = Scripts.get_script!(scope, id)
    owner = Moorland.Repo.preload(script, :owner).owner
    author = owner.email |> String.split("@") |> hd()

    {binary, type} =
      case format do
        "docx" ->
          {Moorland.Scripts.ProseExport.docx(script.content, %{
             title: script.title,
             author: author,
             contact: owner.email
           }), "application/vnd.openxmlformats-officedocument.wordprocessingml.document"}

        "epub" ->
          {Moorland.Scripts.ProseExport.epub(script.content, %{
             title: script.title,
             author: author,
             uid: "moorland-#{script.id}-#{script.content_version}"
           }), "application/epub+zip"}
      end

    send_download(conn, {:binary, binary},
      filename: "#{filename(script.title)}.#{format}",
      content_type: type
    )
  end

  def prose(conn, _params), do: conn |> put_status(404) |> text("Not found")

  defp filename(title) do
    case title |> String.replace(~r/[^\p{L}\p{N} _.-]+/u, "") |> String.trim() do
      "" -> "script"
      name -> name
    end
  end
end
