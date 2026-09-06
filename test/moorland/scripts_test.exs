defmodule Moorland.ScriptsTest do
  use Moorland.DataCase

  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Scripts

  defp scopes(_ctx) do
    owner = user_fixture()
    other = user_fixture()
    %{owner: Scope.for_user(owner), other: Scope.for_user(other), other_user: other}
  end

  defp script(scope, attrs \\ %{title: "Untitled"}) do
    {:ok, script} = Scripts.create_script(scope, attrs)
    script
  end

  setup :scopes

  describe "access control" do
    test "owner has the :owner role", %{owner: owner} do
      s = script(owner)
      assert {_s, :owner} = Scripts.get_script!(owner, s.id)
    end

    test "non-members cannot load the script", %{owner: owner, other: other} do
      s = script(owner)
      assert_raise Ecto.NoResultsError, fn -> Scripts.get_script!(other, s.id) end
    end

    test "collaborator roles gate editing", %{owner: owner, other: other, other_user: other_user} do
      s = script(owner)
      {:ok, _} = Scripts.add_collaborator(owner, s, other_user.email, "viewer")
      {s, :viewer} = Scripts.get_script!(other, s.id)

      assert {:error, :not_allowed} = Scripts.save_content(other, s, "INT. LAB - DAY")
      assert {:error, :not_allowed} = Scripts.create_comment(other, s, %{body: "hi"})

      [collab] = Scripts.list_collaborators(s)
      {:ok, _} = Scripts.update_collaborator_role(owner, s, collab.id, "commenter")
      {s, :commenter} = Scripts.get_script!(other, s.id)

      assert {:ok, _} = Scripts.create_comment(other, s, %{body: "hi"})
      assert {:error, :not_allowed} = Scripts.save_content(other, s, "INT. LAB - DAY")

      {:ok, _} = Scripts.update_collaborator_role(owner, s, collab.id, "editor")
      {s, :editor} = Scripts.get_script!(other, s.id)
      assert {:ok, _} = Scripts.save_content(other, s, "INT. LAB - DAY")
    end

    test "only the owner manages collaborators", %{owner: owner, other: other, other_user: ou} do
      s = script(owner)
      {:ok, _} = Scripts.add_collaborator(owner, s, ou.email, "editor")
      {s, :editor} = Scripts.get_script!(other, s.id)
      assert {:error, :not_allowed} = Scripts.add_collaborator(other, s, "x@example.com", "viewer")
      assert {:error, :not_allowed} = Scripts.delete_script(other, s)
    end

    test "adding an unknown email fails cleanly", %{owner: owner} do
      s = script(owner)
      assert {:error, :user_not_found} = Scripts.add_collaborator(owner, s, "nope@x.com", "editor")
    end

    test "shared scripts appear in the collaborator's list", %{
      owner: owner,
      other: other,
      other_user: ou
    } do
      s = script(owner, %{title: "Shared draft"})
      assert Scripts.list_scripts(other) == []
      {:ok, _} = Scripts.add_collaborator(owner, s, ou.email, "commenter")
      assert [%{id: id}] = Scripts.list_scripts(other)
      assert id == s.id
    end
  end

  describe "merge-safe concurrent saves" do
    test "a stale save merges instead of clobbering", %{owner: owner, other: other, other_user: ou} do
      s = script(owner)
      {:ok, _} = Scripts.add_collaborator(owner, s, ou.email, "editor")
      {s_other, :editor} = Scripts.get_script!(other, s.id)

      base = "INT. LAB - DAY\n\nThe machine hums.\n\nEXT. LOT - NIGHT\n\nRain falls."
      {:ok, s1} = Scripts.save_content(owner, s, base)
      assert s1.content_version == 1

      # Both editors start from version 1. Owner edits the top...
      owner_text = String.replace(base, "The machine hums.", "The machine roars.")
      {:ok, s2} = Scripts.save_content(owner, s1, owner_text, 1)
      assert s2.content_version == 2

      # ...while the collaborator (still on version 1) edits the bottom.
      other_text = String.replace(base, "Rain falls.", "Snow falls.")
      {:ok, s3} = Scripts.save_content(other, s_other, other_text, 1)

      assert s3.content_version == 3
      assert s3.content =~ "The machine roars."
      assert s3.content =~ "Snow falls."
    end

    test "save without a base version stays last-write-wins", %{owner: owner} do
      s = script(owner)
      {:ok, s} = Scripts.save_content(owner, s, "one")
      {:ok, s} = Scripts.save_content(owner, s, "two")
      assert s.content == "two"
      assert s.content_version == 2
    end

    test "merge bases survive a cache wipe (durable store fallback)", %{owner: owner} do
      s = script(owner)
      base = "INT. LAB - DAY\n\nThe machine hums.\n\nEXT. LOT - NIGHT\n\nRain falls."
      {:ok, s1} = Scripts.save_content(owner, s, base)

      # Simulate a restart: the in-memory cache forgets everything.
      :ets.delete_all_objects(Moorland.Scripts.ContentCache)

      {:ok, s2} =
        Scripts.save_content(owner, s1, String.replace(base, "hums", "roars"), 1)

      :ets.delete_all_objects(Moorland.Scripts.ContentCache)

      {:ok, s3} =
        Scripts.save_content(owner, s2, String.replace(base, "Rain falls.", "Snow falls."), 1)

      assert s3.content =~ "roars"
      assert s3.content =~ "Snow falls."
    end
  end

  describe "goals and character metadata" do
    test "goals cast and clear through update_script", %{owner: owner} do
      s = script(owner)
      {:ok, s} = Scripts.update_script(owner, s, %{goal_words: 5000, goal_pages: 90})
      assert s.goal_words == 5000
      assert s.goal_pages == 90
      {:ok, s} = Scripts.update_script(owner, s, %{goal_words: nil})
      assert s.goal_words == nil
    end

    test "character genders upsert and are role-gated", %{owner: owner, other: other, other_user: ou} do
      s = script(owner)
      :ok = Scripts.set_character_gender(owner, s, "NORA", "female")
      :ok = Scripts.set_character_gender(owner, s, "NORA", "nonbinary")
      assert Scripts.list_character_meta(s) == %{"NORA" => "nonbinary"}

      {:ok, _} = Scripts.add_collaborator(owner, s, ou.email, "viewer")
      {s_other, _} = Scripts.get_script!(other, s.id)
      assert {:error, :not_allowed} = Scripts.set_character_gender(other, s_other, "X", "male")
    end
  end

  describe "versions" do
    test "snapshot and restore round-trips content, preserving the pre-restore text", %{
      owner: owner
    } do
      s = script(owner)
      {:ok, s} = Scripts.save_content(owner, s, "draft one")
      {:ok, v1} = Scripts.create_snapshot(owner, s, "First draft")
      {:ok, s} = Scripts.save_content(owner, s, "draft two")

      {:ok, s} = Scripts.restore_version(owner, s, v1)
      assert s.content == "draft one"

      # The restore laid down a safety version holding "draft two"
      kinds = Scripts.list_versions(s) |> Enum.map(& &1.kind)
      assert "restore" in kinds
      assert Enum.any?(Scripts.list_versions(s), &(&1.content == "draft two"))
    end

    test "diff_lines marks insertions and deletions", %{owner: owner} do
      _ = owner
      diff = Scripts.diff_lines("a\nb\nc", "a\nx\nc")
      assert {:del, "b"} in diff
      assert {:ins, "x"} in diff
      assert {:eq, "a"} in diff
    end
  end

  describe "comments" do
    test "threads with replies and resolution", %{owner: owner, other: other, other_user: ou} do
      s = script(owner)
      {:ok, _} = Scripts.add_collaborator(owner, s, ou.email, "commenter")
      {s, _} = Scripts.get_script!(other, s.id)

      {:ok, top} =
        Scripts.create_comment(other, s, %{body: "Too slow?", line_no: 3, anchor_text: "He waits."})

      {:ok, _reply} = Scripts.create_comment(owner, s, %{body: "Agreed", parent_id: top.id})

      [thread] = Scripts.list_comments(s)
      assert thread.line_no == 3
      assert [%{body: "Agreed"}] = thread.replies

      {:ok, _} = Scripts.resolve_comment(owner, s, top.id, true)
      assert Scripts.list_comments(s, include_resolved: false) == []
      assert [_] = Scripts.list_comments(s)
    end

    test "authors delete their own comments; owner can delete any", %{
      owner: owner,
      other: other,
      other_user: ou
    } do
      s = script(owner)
      {:ok, _} = Scripts.add_collaborator(owner, s, ou.email, "commenter")
      {s_other, _} = Scripts.get_script!(other, s.id)

      {:ok, c1} = Scripts.create_comment(other, s_other, %{body: "mine"})
      {:ok, c2} = Scripts.create_comment(owner, s, %{body: "owners"})

      assert {:error, :not_allowed} = Scripts.delete_comment(other, s_other, c2.id)
      assert :ok = Scripts.delete_comment(other, s_other, c1.id)
      assert :ok = Scripts.delete_comment(owner, s, c2.id)
    end
  end

  describe "notes" do
    test "create, pin and delete", %{owner: owner} do
      s = script(owner)
      {:ok, note} = Scripts.create_note(owner, s, %{body: "Research trains", color: "blue"})
      {:ok, note} = Scripts.update_note(owner, s, note.id, %{pinned: true})
      assert note.pinned
      assert [%{pinned: true}] = Scripts.list_notes(s)
      assert :ok = Scripts.delete_note(owner, s, note.id)
      assert Scripts.list_notes(s) == []
    end
  end
end
