defmodule Plausible.SiteAdmin do
  use Plausible.Repo
  import Ecto.Query

  def ordering(_schema) do
    [desc: :inserted_at]
  end

  def search_fields(_schema) do
    [
      :domain,
      members: [:name, :email]
    ]
  end

  def custom_index_query(_conn, _schema, query) do
    from(r in query, preload: [memberships: :user])
  end

  def form_fields(_) do
    [
      domain: %{update: :readonly},
      timezone: %{choices: Plausible.Timezones.options()},
      public: nil,
      stats_start_date: nil,
      ingest_rate_limit_scale_seconds: %{
        help_text: "Time scale for which events rate-limiting is calculated. Default: 60"
      },
      ingest_rate_limit_threshold: %{
        help_text:
          "Keep empty to disable rate limiting, set to 0 to bar all events. Any positive number sets the limit."
      }
    ]
  end

  def index(_) do
    [
      domain: nil,
      inserted_at: %{name: "Created at", value: &format_date(&1.inserted_at)},
      timezone: nil,
      public: nil,
      owner: %{value: &get_owner_email/1},
      other_members: %{value: &get_other_members/1},
      limits: %{
        value: fn site ->
          case site.ingest_rate_limit_threshold do
            nil -> ""
            0 -> "🛑 BLOCKED"
            n -> "⏱ #{n}/#{site.ingest_rate_limit_scale_seconds}s (per server)"
          end
        end
      }
    ]
  end

  def list_actions(_conn) do
    [
      transfer_ownership: %{
        name: "Transfer ownership",
        inputs: [
          %{name: "email", title: "New Owner Email", default: nil}
        ],
        action: fn conn, sites, params -> transfer_ownership(conn, sites, params) end
      },
      transfer_ownership_direct: %{
        name: "Transfer ownership without invite",
        inputs: [
          %{name: "email", title: "New Owner Email", default: nil}
        ],
        action: fn conn, sites, params -> transfer_ownership_direct(conn, sites, params) end
      }
    ]
  end

  defp transfer_ownership(_conn, [], _params) do
    {:error, "Please select at least one site from the list"}
  end

  defp transfer_ownership(conn, sites, %{"email" => email}) do
    new_owner = Plausible.Auth.find_user_by(email: email)
    inviter = conn.assigns[:current_user]

    if new_owner do
      {:ok, _} =
        Plausible.Site.Memberships.bulk_create_invitation(
          sites,
          inviter,
          new_owner.email,
          :owner,
          check_permissions: false
        )

      :ok
    else
      {:error, "User could not be found"}
    end
  end

  defp transfer_ownership_direct(_conn, [], _params) do
    {:error, "Please select at least one site from the list"}
  end

  defp transfer_ownership_direct(_conn, sites, %{"email" => email}) do
    new_owner = Plausible.Auth.find_user_by(email: email)

    if new_owner do
      case Plausible.Site.Memberships.bulk_transfer_ownership_direct(sites, new_owner) do
        {:ok, _} -> :ok
        {:error, :transfer_to_self} -> {:error, "User is already an owner of one of the sites"}
      end
    else
      {:error, "User could not be found"}
    end
  end

  defp format_date(date) do
    Timex.format!(date, "{Mshort} {D}, {YYYY}")
  end

  defp get_owner_email(site) do
    owner = Enum.find(site.memberships, fn m -> m.role == :owner end)

    if owner do
      owner.user.email
    end
  end

  defp get_other_members(site) do
    Enum.filter(site.memberships, &(&1.role != :owner))
    |> Enum.map(fn m -> m.user.email <> "(#{to_string(m.role)})" end)
    |> Enum.join(", ")
  end

  def get_struct_fields(module) do
    module.__struct__()
    |> Map.drop([:__meta__, :__struct__])
    |> Map.keys()
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
  end

  def create_changeset(schema, attrs), do: Plausible.Site.crm_changeset(schema, attrs)
  def update_changeset(schema, attrs), do: Plausible.Site.crm_changeset(schema, attrs)
end
