defmodule Plausible.Goals do
  use Plausible.Repo
  alias Plausible.Goal
  alias Ecto.Multi

  use Plausible.Funnel

  @spec create(Plausible.Site.t(), map(), Keyword.t()) ::
          {:ok, Goal.t()} | {:error, Ecto.Changeset.t()} | {:error, :upgrade_required}
  @doc """
  Creates a Goal for a site.

  If the created goal is a revenue goal, it sets site.updated_at to be
  refreshed by the sites cache, as revenue goals are used during ingestion.
  """
  def create(site, params, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    upsert? = Keyword.get(opts, :upsert?, false)

    Repo.transaction(fn ->
      case insert_goal(site, params, upsert?) do
        {:ok, :insert, goal} ->
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          if Goal.revenue?(goal) do
            Plausible.Site.Cache.touch_site!(site, now)
          end

          Repo.preload(goal, :site)

        {:ok, :upsert, goal} ->
          Repo.preload(goal, :site)

        {:error, cause} ->
          Repo.rollback(cause)
      end
    end)
  end

  def find_or_create(site, %{
        "goal_type" => "event",
        "event_name" => event_name,
        "currency" => currency
      })
      when is_binary(event_name) and is_binary(currency) do
    params = %{"event_name" => event_name, "currency" => currency}

    with {:ok, goal} <- create(site, params, upsert?: true) do
      if to_string(goal.currency) == currency do
        {:ok, goal}
      else
        # we must disallow creation of the same goal name with different currency
        changeset =
          goal
          |> Goal.changeset()
          |> Ecto.Changeset.add_error(
            :event_name,
            "'#{goal.event_name}' (with currency: #{goal.currency}) has already been taken"
          )

        {:error, changeset}
      end
    end
  end

  def find_or_create(site, %{"goal_type" => "event", "event_name" => event_name})
      when is_binary(event_name) do
    create(site, %{"event_name" => event_name}, upsert?: true)
  end

  def find_or_create(_, %{"goal_type" => "event"}), do: {:missing, "event_name"}

  def find_or_create(site, %{"goal_type" => "page", "page_path" => page_path}) do
    create(site, %{"page_path" => page_path}, upsert?: true)
  end

  def find_or_create(_, %{"goal_type" => "page"}), do: {:missing, "page_path"}

  def for_site(site, opts \\ []) do
    site
    |> for_site_query(opts)
    |> Repo.all()
    |> Enum.map(&maybe_trim/1)
  end

  def for_site_query(site, opts \\ []) do
    query =
      from g in Goal,
        inner_join: assoc(g, :site),
        where: g.site_id == ^site.id,
        order_by: [desc: g.id],
        preload: [:site]

    if opts[:preload_funnels?] do
      from(g in query,
        left_join: assoc(g, :funnels),
        group_by: g.id,
        preload: [:funnels]
      )
    else
      query
    end
  end

  @doc """
  If a goal belongs to funnel(s), we need to inspect their number of steps.

  If it exceeds the minimum allowed (defined via `Plausible.Funnel.min_steps/0`),
  the funnel will be reduced (i.e. a step associated with the goal to be deleted
  is removed), so that the minimum number of steps is preserved. This is done
  implicitly, by postgres, as per on_delete: :delete_all.

  Otherwise, for associated funnel(s) consisting of minimum number steps only,
  funnel record(s) are removed completely along with the targeted goal.
  """
  def delete(id, %Plausible.Site{id: site_id}) do
    delete(id, site_id)
  end

  def delete(id, site_id) do
    result =
      Multi.new()
      |> Multi.one(
        :goal,
        from(g in Goal,
          where: g.id == ^id,
          where: g.site_id == ^site_id,
          preload: [funnels: :steps]
        )
      )
      |> Multi.run(:funnel_ids_to_wipe, fn
        _, %{goal: nil} ->
          {:error, :not_found}

        _, %{goal: %{funnels: []}} ->
          {:ok, []}

        _, %{goal: %{funnels: funnels}} ->
          funnels_to_wipe =
            funnels
            |> Enum.filter(&(Enum.count(&1.steps) == Funnel.min_steps()))
            |> Enum.map(& &1.id)

          {:ok, funnels_to_wipe}
      end)
      |> Multi.merge(fn
        %{funnel_ids_to_wipe: []} ->
          Ecto.Multi.new()

        %{funnel_ids_to_wipe: [_ | _] = funnel_ids} ->
          Ecto.Multi.new()
          |> Multi.delete_all(
            :delete_funnels,
            from(f in Funnel,
              where: f.id in ^funnel_ids
            )
          )
      end)
      |> Multi.delete_all(
        :delete_goals,
        fn _ ->
          from g in Goal,
            where: g.id == ^id,
            where: g.site_id == ^site_id
        end
      )
      |> Repo.transaction()

    case result do
      {:ok, _} -> :ok
      {:error, _step, reason, _context} -> {:error, reason}
    end
  end

  @spec count(Plausible.Site.t()) :: non_neg_integer()
  def count(site) do
    Repo.aggregate(
      from(
        g in Goal,
        where: g.site_id == ^site.id
      ),
      :count
    )
  end

  defp insert_goal(site, params, upsert?) do
    params = Map.delete(params, "site_id")

    insert_opts =
      if upsert? do
        [on_conflict: :nothing]
      else
        []
      end

    changeset = Goal.changeset(%Goal{site_id: site.id}, params)

    with :ok <- maybe_check_feature_access(site, changeset),
         {:ok, goal} <- Repo.insert(changeset, insert_opts) do
      # Upsert with `on_conflict: :nothing` strategy
      # will result in goal struct missing primary key field
      # which is generated by the database.
      if goal.id do
        {:ok, :insert, goal}
      else
        get_params =
          goal
          |> Map.take([:site_id, :event_name, :page_path])
          |> Enum.reject(fn {_, value} -> is_nil(value) end)

        {:ok, :upsert, Repo.get_by!(Goal, get_params)}
      end
    end
  end

  defp maybe_check_feature_access(site, changeset) do
    if Ecto.Changeset.get_field(changeset, :currency) do
      site = Plausible.Repo.preload(site, :owner)
      Plausible.Billing.Feature.RevenueGoals.check_availability(site.owner)
    else
      :ok
    end
  end

  defp maybe_trim(%Goal{} = goal) do
    # we make sure that even if we saved goals erroneously with trailing
    # space, it's removed during fetch
    goal
    |> Map.update!(:event_name, &maybe_trim/1)
    |> Map.update!(:page_path, &maybe_trim/1)
  end

  defp maybe_trim(s) when is_binary(s) do
    String.trim(s)
  end

  defp maybe_trim(other) do
    other
  end
end
