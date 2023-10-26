defmodule PlausibleWeb.Api.InternalController do
  use PlausibleWeb, :controller
  use Plausible.Repo
  alias Plausible.Stats.Clickhouse, as: Stats
  alias Plausible.{Sites, Site, Auth}
  alias Plausible.Auth.User

  def domain_status(conn, %{"domain" => domain}) do
    with %User{id: user_id} <- conn.assigns[:current_user],
         %Site{} = site <- Sites.get_by_domain(domain),
         true <- Sites.has_admin_access?(user_id, site) || Auth.is_super_admin?(user_id),
         true <- Stats.has_pageviews?(site) do
      json(conn, "READY")
    else
      _ ->
        json(conn, "WAITING")
    end
  end

  def sites(conn, params) do
    current_user = conn.assigns[:current_user]

    if current_user do
      sites =
        sites_for(current_user, params)
        |> buildResponse(conn)

      json(conn, sites)
    else
      PlausibleWeb.Api.Helpers.unauthorized(
        conn,
        "You need to be logged in to request a list of sites"
      )
    end
  end

  @features %{
    "funnels" => Plausible.Billing.Feature.Funnels,
    "props" => Plausible.Billing.Feature.Props,
    "conversions" => Plausible.Billing.Feature.Goals
  }
  def disable_feature(conn, %{"domain" => domain, "feature" => feature}) do
    with %User{id: user_id} <- conn.assigns[:current_user],
         site <- Sites.get_by_domain(domain),
         true <- Sites.has_admin_access?(user_id, site) || Auth.is_super_admin?(user_id),
         {:ok, mod} <- Map.fetch(@features, feature),
         {:ok, _site} <- mod.toggle(site, override: false) do
      json(conn, "ok")
    else
      {:error, :upgrade_required} ->
        PlausibleWeb.Api.Helpers.payment_required(
          conn,
          "This feature is part of the Plausible Business plan. To get access to this feature, please upgrade your account"
        )

      :error ->
        PlausibleWeb.Api.Helpers.bad_request(
          conn,
          "The feature you tried to disable is not valid. Valid features are: #{@features |> Map.keys() |> Enum.join(", ")}"
        )

      _ ->
        PlausibleWeb.Api.Helpers.unauthorized(
          conn,
          "You need to be logged in as the owner or admin account of this site"
        )
    end
  end

  defp sites_for(user, params) do
    Repo.paginate(
      from(
        s in Site,
        join: sm in Site.Membership,
        on: sm.site_id == s.id,
        where: sm.user_id == ^user.id,
        order_by: s.domain
      ),
      params
    )
  end

  defp buildResponse({sites, pagination}, conn) do
    %{
      data: Enum.map(sites, &%{domain: &1.domain}),
      pagination: Phoenix.Pagination.JSON.paginate(conn, pagination)
    }
  end
end
