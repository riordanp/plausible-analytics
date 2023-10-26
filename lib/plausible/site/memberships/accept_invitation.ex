defmodule Plausible.Site.Memberships.AcceptInvitation do
  @moduledoc """
  Service for accepting invitations, including ownership transfers.

  Accepting invitation accounts for the fact that it's possible
  that accepting user has an existing membership for the site and
  acts permissively to not unnecessarily disrupt the flow while
  also maintaining integrity of site memberships. This also applies
  to cases where users update their email address between issuing
  the invitation and accepting it.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Plausible.Auth
  alias Plausible.Billing
  alias Plausible.Memberships.Invitations
  alias Plausible.Repo
  alias Plausible.Site
  alias Plausible.Site.Memberships.Invitations

  require Logger

  @spec transfer_ownership(Site.t(), Auth.User.t(), Keyword.t()) ::
          {:ok, Site.Membership.t()} | {:error, Ecto.Changeset.t()}
  def transfer_ownership(site, user, opts \\ []) do
    selfhost? = Keyword.get(opts, :selfhost?, Plausible.Release.selfhost?())
    membership = get_or_create_owner_membership(site, user)
    multi = add_and_transfer_ownership(site, membership, user, selfhost?)

    case Repo.transaction(multi) do
      {:ok, changes} ->
        if changes[:site_locker] == {:locked, :grace_period_ended_now} do
          user = Plausible.Users.with_subscription(changes.user)
          Billing.SiteLocker.send_grace_period_end_email(user)
        end

        membership = Repo.preload(changes.membership, [:site, :user])

        {:ok, membership}

      {:error, _operation, error, _changes} ->
        {:error, error}
    end
  end

  @spec accept_invitation(String.t(), Auth.User.t(), Keyword.t()) ::
          {:ok, Site.Membership.t()} | {:error, :invitation_not_found | Ecto.Changeset.t()}
  def accept_invitation(invitation_id, user, opts \\ []) do
    selfhost? = Keyword.get(opts, :selfhost?, Plausible.Release.selfhost?())

    with {:ok, invitation} <- Invitations.find_for_user(invitation_id, user) do
      membership = get_or_create_membership(invitation, user)

      multi =
        if invitation.role == :owner do
          invitation.site
          |> add_and_transfer_ownership(membership, user, selfhost?)
          |> Multi.delete(:invitation, invitation)
        else
          add(invitation, membership, user)
        end

      case Repo.transaction(multi) do
        {:ok, changes} ->
          if changes[:site_locker] == {:locked, :grace_period_ended_now} do
            user = Plausible.Users.with_subscription(changes.user)
            Billing.SiteLocker.send_grace_period_end_email(user)
          end

          notify_invitation_accepted(invitation)

          membership = Repo.preload(changes.membership, [:site, :user])

          {:ok, membership}

        {:error, _operation, error, _changes} ->
          {:error, error}
      end
    end
  end

  defp add_and_transfer_ownership(site, membership, user, selfhost?) do
    multi =
      Multi.new()
      |> downgrade_previous_owner(site, user)
      |> maybe_end_trial_of_new_owner(user, selfhost?)
      |> Multi.insert_or_update(:membership, membership)

    if selfhost? do
      multi
    else
      Multi.run(multi, :site_locker, fn _, %{user: updated_user} ->
        {:ok, Billing.SiteLocker.update_sites_for(updated_user, send_email?: false)}
      end)
    end
  end

  # If there's an existing membership, we DO NOT change the role
  # to avoid accidental role downgrade.
  defp add(invitation, membership, _user) do
    if membership.data.id do
      Multi.new()
      |> Multi.put(:membership, membership.data)
      |> Multi.delete(:invitation, invitation)
    else
      Multi.new()
      |> Multi.insert(:membership, membership)
      |> Multi.delete(:invitation, invitation)
    end
  end

  defp get_or_create_membership(invitation, user) do
    case Repo.get_by(Site.Membership, user_id: user.id, site_id: invitation.site.id) do
      nil -> Site.Membership.new(invitation.site, user)
      membership -> membership
    end
    |> Site.Membership.set_role(invitation.role)
  end

  defp get_or_create_owner_membership(site, user) do
    case Repo.get_by(Site.Membership, user_id: user.id, site_id: site.id) do
      nil -> Site.Membership.new(site, user)
      membership -> membership
    end
    |> Site.Membership.set_role(:owner)
  end

  # If the new owner is the same as old owner, we do not downgrade them
  # to avoid leaving site without an owner!
  defp downgrade_previous_owner(multi, site, new_owner) do
    new_owner_id = new_owner.id

    previous_owner =
      Repo.one(
        from(
          sm in Site.Membership,
          where: sm.site_id == ^site.id,
          where: sm.role == :owner
        )
      )

    case previous_owner do
      %{user_id: ^new_owner_id} ->
        Multi.put(multi, :previous_owner_membership, previous_owner)

      nil ->
        Logger.warning(
          "Transferring ownership from a site with no owner: #{site.domain} " <>
            ", new owner ID: #{new_owner_id}"
        )

        Multi.put(multi, :previous_owner_membership, nil)

      previous_owner ->
        Multi.update(
          multi,
          :previous_owner_membership,
          Site.Membership.set_role(previous_owner, :admin)
        )
    end
  end

  # If the new owner is the same as the old owner, it's a no-op
  defp maybe_end_trial_of_new_owner(multi, new_owner, selfhost?) do
    new_owner_id = new_owner.id

    cond do
      selfhost? ->
        Multi.put(multi, :user, new_owner)

      Billing.on_trial?(new_owner) or is_nil(new_owner.trial_expiry_date) ->
        Multi.update(multi, :user, fn
          %{previous_owner_membership: %{user_id: ^new_owner_id}} ->
            Ecto.Changeset.change(new_owner)

          _ ->
            Auth.User.end_trial(new_owner)
        end)

      true ->
        Multi.put(multi, :user, new_owner)
    end
  end

  defp notify_invitation_accepted(%Auth.Invitation{role: :owner} = invitation) do
    PlausibleWeb.Email.ownership_transfer_accepted(invitation)
    |> Plausible.Mailer.send()
  end

  defp notify_invitation_accepted(invitation) do
    PlausibleWeb.Email.invitation_accepted(invitation)
    |> Plausible.Mailer.send()
  end
end
