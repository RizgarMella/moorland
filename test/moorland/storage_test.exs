defmodule Moorland.StorageTest do
  use Moorland.DataCase

  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Scripts
  alias Moorland.Storage

  setup do
    base = Path.join(System.tmp_dir!(), "moorland_storage_test_#{System.unique_integer([:positive])}")
    mirror_dir = Path.join(base, "scripts")
    pointer = Path.join(base, "data_dir_pointer")

    Application.put_env(:moorland, :mirror_scripts, true)
    Application.put_env(:moorland, :mirror_dir, mirror_dir)
    Application.put_env(:moorland, :data_dir_pointer, pointer)

    on_exit(fn ->
      Application.put_env(:moorland, :mirror_scripts, false)
      Application.delete_env(:moorland, :mirror_dir)
      Application.delete_env(:moorland, :data_dir_pointer)
      File.rm_rf(base)
    end)

    %{scope: Scope.for_user(user_fixture()), base: base, mirror_dir: mirror_dir, pointer: pointer}
  end

  test "scripts are mirrored as plain .fountain files on create, save, rename, delete", %{
    scope: scope,
    mirror_dir: mirror_dir
  } do
    {:ok, script} = Scripts.create_script(scope, %{title: "My Play", content: "INT. A - DAY"})

    path = Path.join(mirror_dir, "My Play (#{script.id}).fountain")
    assert File.read!(path) == "INT. A - DAY"

    {:ok, script} = Scripts.save_content(scope, script, "INT. A - NIGHT")
    assert File.read!(path) == "INT. A - NIGHT"

    {:ok, script} = Scripts.update_script(scope, script, %{title: "Renamed: Play?"})
    refute File.exists?(path)
    renamed = Path.join(mirror_dir, "Renamed Play (#{script.id}).fountain")
    assert File.read!(renamed) == "INT. A - NIGHT"

    {:ok, _} = Scripts.delete_script(scope, script)
    refute File.exists?(renamed)
  end

  test "mirror_all backfills every script", %{scope: scope, mirror_dir: mirror_dir} do
    {:ok, a} = Scripts.create_script(scope, %{title: "One", content: "a"})
    {:ok, b} = Scripts.create_script(scope, %{title: "Two", content: "b"})

    File.rm_rf!(mirror_dir)
    :ok = Storage.mirror_all()

    assert File.exists?(Path.join(mirror_dir, "One (#{a.id}).fountain"))
    assert File.exists?(Path.join(mirror_dir, "Two (#{b.id}).fountain"))
  end

  test "relocate copies the database and writes the pointer", %{base: base, pointer: pointer} do
    target = Path.join(base, "new_home")

    assert {:ok, :copied, dir} = Storage.relocate(target)
    assert dir == Path.expand(target)
    assert File.exists?(Path.join(dir, "moorland.db"))
    assert String.trim(File.read!(pointer)) == dir

    # A folder that already holds a moorland.db is adopted, not overwritten.
    marker = Path.join(dir, "moorland.db")
    File.write!(marker, "existing data")
    assert {:ok, :adopted, ^dir} = Storage.relocate(target)
    assert File.read!(marker) == "existing data"
  end
end
