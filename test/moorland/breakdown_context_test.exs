defmodule Moorland.BreakdownContextTest do
  use Moorland.DataCase

  import Moorland.AccountsFixtures

  alias Moorland.Accounts.Scope
  alias Moorland.Scripts

  @content """
  INT. GARAGE - NIGHT

  A *red* bicycle leans on the wall.

  EXT. ROAD - DAY

  The bicycle speeds past.
  """

  setup do
    owner = Scope.for_user(user_fixture())
    other_user = user_fixture()
    other = Scope.for_user(other_user)
    {:ok, script} = Scripts.create_script(owner, %{title: "Ride"})
    {:ok, script} = Scripts.save_content(owner, script, @content)
    %{owner: owner, other: other, other_user: other_user, script: script}
  end

  defp add_member(owner, script, user, role) do
    {:ok, _} = Scripts.add_collaborator(owner, script, user.email, role)
  end

  test "tags trim the anchor to the words on the line", %{owner: owner, script: s} do
    {:ok, tag} =
      Scripts.create_breakdown_tag(owner, s, %{
        category: "props",
        name: "  Red   bicycle ",
        anchor_text: "red bicycle leans on the wall. EXT. ROAD",
        line_no: 2
      })

    assert tag.name == "Red bicycle"
    assert tag.anchor_text == "red bicycle leans on the wall."
    assert [%{id: id}] = Scripts.list_breakdown_tags(s)
    assert id == tag.id
  end

  test "a tag without words belongs to the scene on its line", %{owner: owner, script: s} do
    {:ok, tag} =
      Scripts.create_breakdown_tag(owner, s, %{category: "sfx", name: "Rain", line_no: "4"})

    assert tag.anchor_text == nil and tag.line_no == 4
  end

  test "rejects unknown categories and blank names", %{owner: owner, script: s} do
    assert {:error, cs} =
             Scripts.create_breakdown_tag(owner, s, %{category: "snacks", name: "x", line_no: 0})

    assert "is invalid" in errors_on(cs).category

    assert {:error, cs} =
             Scripts.create_breakdown_tag(owner, s, %{category: "props", name: " ", line_no: 0})

    assert "can't be blank" in errors_on(cs).name
  end

  test "viewers cannot tag; commenters can", ctx do
    %{owner: owner, other: other, other_user: other_user, script: s} = ctx
    attrs = %{category: "props", name: "Bicycle", anchor_text: "bicycle", line_no: 2}

    add_member(owner, s, other_user, "viewer")
    assert {:error, :not_allowed} = Scripts.create_breakdown_tag(other, s, attrs)

    {:ok, _} = Scripts.update_collaborator_role(owner, s, collab_id(s), "commenter")
    assert {:ok, _} = Scripts.create_breakdown_tag(other, s, attrs)
  end

  test "a commenter may remove only their own tags", ctx do
    %{owner: owner, other: other, other_user: other_user, script: s} = ctx
    add_member(owner, s, other_user, "commenter")
    attrs = %{category: "props", name: "Bicycle", anchor_text: "bicycle", line_no: 2}

    {:ok, mine} = Scripts.create_breakdown_tag(other, s, attrs)
    {:ok, theirs} = Scripts.create_breakdown_tag(owner, s, attrs)

    assert {:error, :not_allowed} = Scripts.delete_breakdown_tag(other, s, theirs.id)
    assert :ok = Scripts.delete_breakdown_tag(other, s, mine.id)
    assert :ok = Scripts.delete_breakdown_tag(owner, s, theirs.id)
    assert Scripts.list_breakdown_tags(s) == []
  end

  test "ids that are not ids are not found", %{owner: owner, script: s} do
    assert {:error, :not_allowed} = Scripts.delete_breakdown_tag(owner, s, "abc")
    assert {:error, :not_found} = Scripts.remove_schedule_item(owner, s, "1; drop")
    assert {:error, :not_found} = Scripts.update_day_break(owner, s, nil, %{"note" => "x"})
  end

  test "tags from another script cannot be deleted through this one", %{owner: owner, script: s} do
    {:ok, elsewhere} = Scripts.create_script(owner, %{title: "Other"})

    {:ok, tag} =
      Scripts.create_breakdown_tag(owner, elsewhere, %{category: "sfx", name: "Rain", line_no: 0})

    assert {:error, :not_allowed} = Scripts.delete_breakdown_tag(owner, s, tag.id)
  end

  test "renaming an element renames every tag of it, and editors only", ctx do
    %{owner: owner, other: other, other_user: other_user, script: s} = ctx
    add_member(owner, s, other_user, "commenter")

    for line <- [2, 6] do
      {:ok, _} =
        Scripts.create_breakdown_tag(owner, s, %{
          category: "props",
          name: "bicycle",
          anchor_text: "bicycle",
          line_no: line
        })
    end

    assert {:error, :not_allowed} =
             Scripts.update_breakdown_element(other, s, "props", "bicycle", %{name: "Bike"})

    assert {:ok, 2} =
             Scripts.update_breakdown_element(owner, s, "props", "bicycle", %{
               name: "Racing bike",
               category: "vehicles"
             })

    assert [%{name: "Racing bike", category: "vehicles"}, %{name: "Racing bike"}] =
             Scripts.list_breakdown_tags(s)

    assert {:error, _cs} =
             Scripts.update_breakdown_element(owner, s, "vehicles", "racing bike", %{name: ""})
  end

  test "tagging broadcasts to the script's subscribers", %{owner: owner, script: s} do
    Scripts.subscribe(s.id)

    {:ok, _} =
      Scripts.create_breakdown_tag(owner, s, %{category: "sfx", name: "Rain", line_no: 0})

    assert_receive {:breakdown_changed, id} when id == s.id
  end

  defp collab_id(script) do
    [collab] = Scripts.list_collaborators(script)
    collab.id
  end
end
