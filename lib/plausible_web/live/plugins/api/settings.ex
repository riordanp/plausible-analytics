defmodule PlausibleWeb.Live.Plugins.API.Settings do
  @moduledoc """
  LiveView allowing listing, creating and revoking Plugins API tokens.
  """
  use Phoenix.LiveView
  use Phoenix.HTML

  alias Plausible.Sites
  alias Plausible.Plugins.API.Tokens

  def mount(
        _params,
        %{"domain" => domain, "current_user_id" => user_id} = session,
        socket
      ) do
    socket =
      socket
      |> assign_new(:site, fn ->
        Sites.get_for_user!(user_id, domain, [:owner, :admin, :super_admin])
      end)
      |> assign_new(:displayed_tokens, fn %{site: site} ->
        Tokens.list(site)
      end)

    {:ok,
     assign(socket,
       domain: domain,
       add_token?: not is_nil(session["new_token"]),
       token_description: String.capitalize(session["new_token"] || ""),
       current_user_id: user_id
     )}
  end

  def render(assigns) do
    ~H"""
    <.live_component id="embedded_liveview_flash" module={PlausibleWeb.Live.Flash} flash={@flash} />

    <%= if @add_token? do %>
      <%= live_render(
        @socket,
        PlausibleWeb.Live.Plugins.API.TokenForm,
        id: "token-form",
        session: %{
          "current_user_id" => @current_user_id,
          "domain" => @domain,
          "token_description" => @token_description,
          "rendered_by" => self()
        }
      ) %>
    <% end %>

    <div class="mt-4">
      <div class="border-t border-gray-200 pt-4 grid">
        <div class="mt-4 sm:ml-4 sm:mt-0 justify-self-end">
          <button type="button" phx-click="add-token" class="button">
            + Add Token
          </button>
        </div>
      </div>

      <div
        :if={not Enum.empty?(@displayed_tokens)}
        class="mt-8 overflow-hidden border-b border-gray-200 shadow dark:border-gray-900 sm:rounded-lg"
      >
        <table class="min-w-full divide-y divide-gray-200 dark:divide-gray-900">
          <thead class="bg-gray-50 dark:bg-gray-900">
            <tr>
              <th
                scope="col"
                class="px-6 py-3 text-xs font-medium text-left text-gray-500 uppercase dark:text-gray-100"
              >
                Description
              </th>
              <th
                scope="col"
                class="px-6 py-3 text-xs font-medium text-left text-gray-500 uppercase dark:text-gray-100"
              >
                Hint
              </th>
              <th
                scope="col"
                class="px-6 py-3 text-xs font-medium text-left text-gray-500 uppercase dark:text-gray-100"
              >
                Last used
              </th>
              <th scope="col" class="px-6 py-3">
                <span class="sr-only">Revoke</span>
              </th>
            </tr>
          </thead>
          <tbody>
            <%= for token <- @displayed_tokens do %>
              <tr class="bg-white dark:bg-gray-800">
                <td class="px-6 py-4 text-sm font-medium text-gray-900 dark:text-gray-100">
                  <span class="token-description">
                    <%= token.description %>
                  </span>
                </td>
                <td class="px-6 py-4 text-sm text-gray-500 dark:text-gray-100 font-mono">
                  **********<%= token.hint %>
                </td>
                <td class="px-6 py-4 text-sm font-normal whitespace-nowrap">
                  <%= Plausible.Plugins.API.Token.last_used_humanize(token) %>
                </td>
                <td class="px-6 py-4 text-sm font-medium text-right">
                  <button
                    id={"revoke-token-#{token.id}"}
                    phx-click="revoke-token"
                    phx-value-token-id={token.id}
                    class="text-sm text-red-600"
                    data-confirm="Are you sure you want to revoke this Token? This action cannot be reversed."
                  >
                    Revoke
                  </button>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  def handle_event("add-token", _params, socket) do
    {:noreply, assign(socket, :add_token?, true)}
  end

  def handle_event("revoke-token", %{"token-id" => token_id}, socket) do
    :ok = Tokens.delete(socket.assigns.site, token_id)
    displayed_tokens = Enum.reject(socket.assigns.displayed_tokens, &(&1.id == token_id))
    {:noreply, assign(socket, add_token?: false, displayed_tokens: displayed_tokens)}
  end

  def handle_info(:cancel_add_token, socket) do
    {:noreply, assign(socket, add_token?: false)}
  end

  def handle_info({:token_added, token}, socket) do
    displayed_tokens = [token | socket.assigns.displayed_tokens]

    socket = put_flash(socket, :success, "Plugins API Token created successfully")

    Process.send_after(self(), :clear_flash, 5000)

    {:noreply,
     assign(socket,
       displayed_tokens: displayed_tokens,
       add_token?: false,
       token_description: ""
     )}
  end

  def handle_info(:clear_flash, socket) do
    {:noreply, clear_flash(socket)}
  end
end
