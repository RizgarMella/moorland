defmodule Moorland.Repo.Migrations.AddPageLock do
  use Ecto.Migration

  # Locked pages: the text as it stood when pages were locked, and where each
  # page began (%{"base" => text, "pages" => [%{"page" => "12", "line" => 340}]}).
  # The editor follows those lines through later edits so page numbers hold.
  def change do
    alter table(:scripts) do
      add :page_lock, :map
    end
  end
end
