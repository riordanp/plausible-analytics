defmodule Plausible.AuthTest do
  use Plausible.DataCase, async: true
  alias Plausible.Auth

  describe "user_completed_setup?" do
    test "is false if user does not have any sites" do
      user = insert(:user)

      refute Auth.has_active_sites?(user)
    end

    test "is false if user does not have any events" do
      user = insert(:user)
      insert(:site, members: [user])

      refute Auth.has_active_sites?(user)
    end

    test "is true if user does have events" do
      user = insert(:user)
      site = insert(:site, members: [user])

      populate_stats(site, [
        build(:pageview)
      ])

      assert Auth.has_active_sites?(user)
    end

    test "can specify which roles we're looking for" do
      user = insert(:user)

      insert(:site,
        domain: "test-site.com",
        memberships: [
          build(:site_membership, user: user, role: :admin)
        ]
      )

      refute Auth.has_active_sites?(user, [:owner])
    end
  end

  test "enterprise_configured?/1 returns whether the user has an enterprise plan" do
    user_without_plan = insert(:user)
    user_with_plan = insert(:user, enterprise_plan: build(:enterprise_plan))

    assert Auth.enterprise_configured?(user_with_plan)
    refute Auth.enterprise_configured?(user_without_plan)
    refute Auth.enterprise_configured?(nil)
  end

  describe "create_api_key/3" do
    test "creates a new api key" do
      user = insert(:user)
      key = Ecto.UUID.generate()
      assert {:ok, %Auth.ApiKey{}} = Auth.create_api_key(user, "my new key", key)
    end

    test "errors when key already exists" do
      u1 = insert(:user)
      u2 = insert(:user)
      key = Ecto.UUID.generate()
      assert {:ok, %Auth.ApiKey{}} = Auth.create_api_key(u1, "my new key", key)
      assert {:error, changeset} = Auth.create_api_key(u2, "my other key", key)

      assert changeset.errors[:key] ==
               {"has already been taken",
                [constraint: :unique, constraint_name: "api_keys_key_hash_index"]}
    end

    test "returns error when user is on a growth plan" do
      user = insert(:user, subscription: build(:growth_subscription))

      assert {:error, :upgrade_required} =
               Auth.create_api_key(user, "my new key", Ecto.UUID.generate())
    end
  end

  describe "delete_api_key/2" do
    test "deletes the record" do
      user = insert(:user)
      assert {:ok, api_key} = Auth.create_api_key(user, "my new key", Ecto.UUID.generate())
      assert :ok = Auth.delete_api_key(user, api_key.id)
      refute Plausible.Repo.reload(api_key)
    end

    test "returns error when api key does not exist or does not belong to user" do
      me = insert(:user)

      other_user = insert(:user)
      {:ok, other_api_key} = Auth.create_api_key(other_user, "my new key", Ecto.UUID.generate())

      assert {:error, :not_found} = Auth.delete_api_key(me, other_api_key.id)
      assert {:error, :not_found} = Auth.delete_api_key(me, -1)
    end
  end
end
