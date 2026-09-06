defmodule Moorland.TierTwoTest do
  use Moorland.DataCase

  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.{Scripts, Contacts, Lookup}

  defp scopes(_ctx) do
    owner = user_fixture()
    other = user_fixture()
    %{owner: Scope.for_user(owner), other: Scope.for_user(other), other_user: other}
  end

  setup :scopes

  describe "bin & shelf" do
    test "cut text lands in the bin, moves to shelf, inserts anywhere", %{owner: owner} do
      {:ok, script} = Scripts.create_script(owner, %{title: "S", content: "x"})

      {:ok, snip} = Scripts.create_bin_snippet(owner, script, "NORA\nCut this line.")
      assert [%{body: "NORA\nCut this line."}] = Scripts.list_bin(script)

      {:ok, _} = Scripts.move_snippet_to_shelf(owner, snip.id)
      assert Scripts.list_bin(script) == []
      assert [%{script_id: nil}] = Scripts.list_shelf(owner)

      {:ok, _} = Scripts.delete_snippet(owner, snip.id)
      assert Scripts.list_shelf(owner) == []
    end

    test "shelf is private; bin respects roles", %{owner: owner, other: other, other_user: ou} do
      {:ok, script} = Scripts.create_script(owner, %{title: "S"})
      {:ok, _} = Scripts.create_shelf_snippet(owner, "mine")
      assert Scripts.list_shelf(other) == []

      {:ok, _} = Scripts.add_collaborator(owner, script, ou.email, "viewer")
      {script_other, _} = Scripts.get_script!(other, script.id)
      assert {:error, :not_allowed} = Scripts.create_bin_snippet(other, script_other, "nope")
    end
  end

  describe "search" do
    test "finds scripts, comments and notes the user can access", %{
      owner: owner,
      other: other,
      other_user: ou
    } do
      {:ok, s1} = Scripts.create_script(owner, %{title: "Harbor", content: "The tide rises."})
      {:ok, _s2} = Scripts.create_script(other, %{title: "Private", content: "tide secrets"})
      {:ok, _} = Scripts.create_comment(owner, s1, %{body: "the tide metaphor lands"})
      {:ok, _} = Scripts.create_note(owner, s1, %{body: "research tide charts"})

      results = Scripts.search(owner, "tide")
      kinds = results |> Enum.map(& &1.kind) |> Enum.sort()
      assert kinds == [:comment, :note, :script]
      assert Enum.all?(results, &(&1.script_id == s1.id))

      # No leakage: the other user's private script never surfaces.
      assert Scripts.search(owner, "secrets") == []
    end

    test "short queries return nothing", %{owner: owner} do
      assert Scripts.search(owner, "a") == []
    end
  end

  describe "notifications" do
    test "comments notify members; @mentions are flagged; reading clears", %{
      owner: owner,
      other: other,
      other_user: ou
    } do
      {:ok, script} = Scripts.create_script(owner, %{title: "N"})
      {:ok, _} = Scripts.add_collaborator(owner, script, ou.email, "commenter")

      local = ou.email |> String.split("@") |> hd()
      {:ok, _} = Scripts.create_comment(owner, script, %{body: "hey @#{local}, thoughts?"})

      unread = Scripts.unread_notifications(other)
      assert unread[script.id] == 1

      # The author gets no notification about their own comment.
      assert Scripts.unread_notifications(owner) == %{}

      :ok = Scripts.mark_notifications_read(other, script)
      assert Scripts.unread_notifications(other) == %{}
    end
  end

  describe "contacts" do
    test "crud, scoped to the owner", %{owner: owner, other: other} do
      {:ok, c} =
        Contacts.create_contact(owner, %{
          "name" => "Sam Grip",
          "role" => "Gaffer",
          "department" => "Electric"
        })

      assert [%{name: "Sam Grip"}] = Contacts.list_contacts(owner)
      assert Contacts.list_contacts(other) == []
      assert {:error, :not_found} = Contacts.delete_contact(other, c.id)

      {:ok, updated} = Contacts.update_contact(owner, c.id, %{"role" => "Best Boy"})
      assert updated.role == "Best Boy"
      {:ok, _} = Contacts.delete_contact(owner, c.id)
      assert Contacts.list_contacts(owner) == []
    end
  end

  describe "lookup parsing" do
    test "datamuse defs expand part-of-speech tags" do
      parsed =
        Lookup.parse_definitions([
          %{"defs" => ["n\ta narrow street", "adj\tnear the back", "weird entry"]}
        ])

      assert parsed == [
               {"noun", "a narrow street"},
               {"adjective", "near the back"},
               {"", "weird entry"}
             ]
    end

    test "missing defs are tolerated" do
      assert Lookup.parse_definitions([%{"word" => "x"}]) == []
      assert Lookup.parse_definitions([]) == []
    end
  end
end
