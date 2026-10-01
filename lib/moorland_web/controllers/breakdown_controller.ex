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

  @doc "A shot's storyboard frame, for anyone who can open the script."
  def shot_image(conn, %{"id" => id, "shot_id" => shot_id}) do
    scope = conn.assigns.current_scope
    {script, _role} = Scripts.get_script!(scope, id)

    case Scripts.shot_image(scope, script, shot_id) do
      {:ok, path, type} ->
        conn
        |> put_resp_content_type(type, nil)
        |> put_resp_header("cache-control", "private, max-age=86400")
        |> send_file(200, path)

      {:error, _} ->
        conn |> put_status(404) |> text("Not found")
    end
  end

  @doc """
  A media library file, for anyone who can open the script. Pictures,
  PDFs, sound and video open in the browser; `?download=1` saves the file
  under the name it was added with.
  """
  def media_file(conn, %{"id" => id, "item_id" => item_id} = params) do
    scope = conn.assigns.current_scope
    {script, _role} = Scripts.get_script!(scope, id)

    case Scripts.media_file(scope, script, item_id) do
      {:ok, item, path, type} ->
        disposition = if params["download"] == "1", do: "attachment", else: "inline"

        conn
        |> put_resp_content_type(type, nil)
        |> put_resp_header(
          "content-disposition",
          ~s(#{disposition}; filename="#{download_name(item.filename)}")
        )
        |> put_resp_header("cache-control", "private, max-age=86400")
        |> send_file(200, path)

      {:error, _} ->
        conn |> put_status(404) |> text("Not found")
    end
  end

  defp download_name(name) do
    case name |> to_string() |> String.replace(~r/[^\p{L}\p{N} _.()-]+/u, "") |> String.trim() do
      "" -> "file"
      clean -> clean
    end
  end

  defp filename(title) do
    case title |> String.replace(~r/[^\p{L}\p{N} _.-]+/u, "") |> String.trim() do
      "" -> "script"
      name -> name
    end
  end
end
