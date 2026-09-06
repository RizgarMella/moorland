defmodule Moorland.UpdatesTest do
  use ExUnit.Case, async: true

  alias Moorland.Updates

  describe "version comparison" do
    test "normalizes v-prefixes and short versions" do
      assert Updates.normalize("v1.2.3") == "1.2.3"
      assert Updates.normalize("1.2") == "1.2.0"
      assert Updates.normalize("2") == "2.0.0"
    end

    test "newer? compares semver, tolerating garbage" do
      assert Updates.newer?("v0.2.0", "0.1.0")
      refute Updates.newer?("0.1.0", "0.1.0")
      refute Updates.newer?("0.1.0", "v0.2.0")
      assert Updates.newer?("1.0", "0.9.9")
      refute Updates.newer?("not-a-version", "0.1.0")
    end
  end

  describe "parse_releases/1" do
    test "maps GitHub JSON, drops tagless entries, sorts newest first" do
      releases =
        Updates.parse_releases([
          %{"tag_name" => "v0.1.0", "html_url" => "u1", "published_at" => "2026-01-01T00:00:00Z"},
          %{"name" => "junk without tag"},
          %{
            "tag_name" => "v0.3.0",
            "name" => "Big one",
            "html_url" => "u3",
            "prerelease" => true,
            "published_at" => "2026-08-01T00:00:00Z"
          },
          %{"tag_name" => "v0.2.0", "html_url" => "u2", "published_at" => "2026-05-01T00:00:00Z"}
        ])

      assert Enum.map(releases, & &1.tag) == ["v0.3.0", "v0.2.0", "v0.1.0"]
      assert Enum.at(releases, 0).prerelease
      assert Enum.at(releases, 1).date == "2026-05-01"
    end
  end

  describe "pick_banner/2" do
    defp release(tag, opts \\ []) do
      %{
        tag: tag,
        name: tag,
        url: "https://example.com/#{tag}",
        prerelease: Keyword.get(opts, :prerelease, false),
        date: "2026-08-01"
      }
    end

    test "nil when up to date or when there are no releases" do
      assert Updates.pick_banner([], "0.1.0") == nil
      assert Updates.pick_banner([release("v0.1.0")], "0.1.0") == nil
    end

    test "banner appears for a newer stable release, latest highlighted" do
      releases = [release("v0.3.0"), release("v0.2.0"), release("v0.1.0")]
      banner = Updates.pick_banner(releases, "0.1.0")

      assert banner.latest.tag == "v0.3.0"
      assert banner.current == "0.1.0"
      assert [%{latest: true}, %{latest: false}, %{latest: false, current: true}] = banner.releases
    end

    test "prereleases are skipped when choosing the headline version" do
      releases = [release("v0.4.0-rc.1", prerelease: true), release("v0.3.0")]
      banner = Updates.pick_banner(releases, "0.1.0")
      assert banner.latest.tag == "v0.3.0"
    end

    test "status is safe when the checker isn't running" do
      assert %{releases: [], error: :not_running} = Updates.status()
      assert Updates.banner_info() == nil
    end
  end
end
