defmodule Plausible.Site.Memberships do
  @moduledoc """
  API for site memberships and invitations
  """

  import Ecto.Query, only: [from: 2]

  alias Plausible.Auth
  alias Plausible.Repo
  alias Plausible.Site.Memberships

  defdelegate transfer_ownership(site, user), to: Memberships.AcceptInvitation
  defdelegate accept_invitation(invitation_id, user), to: Memberships.AcceptInvitation
  defdelegate reject_invitation(invitation_id, user), to: Memberships.RejectInvitation
  defdelegate remove_invitation(invitation_id, site), to: Memberships.RemoveInvitation

  defdelegate create_invitation(site, inviter, invitee_email, role),
    to: Memberships.CreateInvitation

  defdelegate bulk_create_invitation(sites, inviter, invitee_email, role, opts),
    to: Memberships.CreateInvitation

  defdelegate bulk_transfer_ownership_direct(sites, new_owner), to: Memberships.CreateInvitation

  @spec any?(Auth.User.t()) :: boolean()
  def any?(user) do
    user
    |> Ecto.assoc(:site_memberships)
    |> Repo.exists?()
  end

  @spec has_any_invitations?(String.t()) :: boolean()
  def has_any_invitations?(email) do
    Repo.exists?(
      from(i in Plausible.Auth.Invitation,
        where: i.email == ^email
      )
    )
  end
end
