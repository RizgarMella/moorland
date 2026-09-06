defmodule MoorlandWeb.ContactLive.Index do
  use MoorlandWeb, :live_view

  alias Moorland.Contacts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, refresh(socket)}
  end

  defp refresh(socket) do
    assign(socket,
      page_title: "Contacts",
      contacts: Contacts.list_contacts(socket.assigns.current_scope),
      editing: nil
    )
  end

  @impl true
  def handle_event("create", params, socket) do
    case Contacts.create_contact(socket.assigns.current_scope, params) do
      {:ok, _} -> {:noreply, refresh(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "A name is required.")}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply, assign(socket, :editing, String.to_integer(id))}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :editing, nil)}
  end

  def handle_event("update", %{"contact_id" => id} = params, socket) do
    Contacts.update_contact(socket.assigns.current_scope, String.to_integer(id), params)
    {:noreply, refresh(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    Contacts.delete_contact(socket.assigns.current_scope, String.to_integer(id))
    {:noreply, refresh(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl py-10">
        <div class="flex items-center gap-3">
          <.link navigate={~p"/scripts"} class="rounded p-1.5 text-base-content/60 hover:bg-base-200">
            <.icon name="hero-chevron-left" class="size-4" />
          </.link>
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Contacts</h1>
            <p class="mt-1 text-sm text-base-content/60">
              Cast, crew and collaborators — the rolodex behind future call sheets.
            </p>
          </div>
        </div>

        <form
          id="contact-create"
          phx-submit="create"
          class="mt-6 rounded-lg border border-base-300 p-4"
        >
          <div class="flex flex-wrap gap-2">
            <input
              type="text"
              name="name"
              required
              placeholder="Name"
              autocomplete="off"
              class="input input-bordered input-sm min-w-40 flex-1"
            />
            <input
              type="text"
              name="role"
              placeholder="Role (e.g. Director, NORA)"
              autocomplete="off"
              class="input input-bordered input-sm min-w-40 flex-1"
            />
            <input
              type="text"
              name="department"
              placeholder="Department"
              autocomplete="off"
              class="input input-bordered input-sm w-36"
            />
          </div>
          <div class="mt-2 flex flex-wrap gap-2">
            <input
              type="email"
              name="email"
              placeholder="Email"
              autocomplete="off"
              class="input input-bordered input-sm min-w-40 flex-1"
            />
            <input
              type="text"
              name="phone"
              placeholder="Phone"
              autocomplete="off"
              class="input input-bordered input-sm w-40"
            />
            <button type="submit" class="btn btn-neutral btn-sm">
              <.icon name="hero-plus" class="size-4" /> Add
            </button>
          </div>
        </form>

        <div class="mt-6 divide-y divide-base-200 rounded-lg border border-base-300">
          <div :for={contact <- @contacts} class="px-4 py-3">
            <div :if={@editing != contact.id} class="flex items-center gap-3">
              <div class="min-w-0 flex-1">
                <div class="flex items-baseline gap-2">
                  <span class="truncate text-sm font-medium">{contact.name}</span>
                  <span :if={contact.role} class="text-xs text-base-content/60">{contact.role}</span>
                  <span
                    :if={contact.department}
                    class="rounded bg-base-200 px-1.5 text-[10px] uppercase text-base-content/50"
                  >
                    {contact.department}
                  </span>
                </div>
                <div class="mt-0.5 text-[11px] text-base-content/50">
                  {[contact.email, contact.phone]
                  |> Enum.reject(&(&1 in [nil, ""]))
                  |> Enum.join(" · ")}
                </div>
              </div>
              <button
                phx-click="edit"
                phx-value-id={contact.id}
                class="rounded p-1 text-base-content/40 hover:text-base-content"
                title="Edit"
              >
                <.icon name="hero-pencil" class="size-4" />
              </button>
              <button
                phx-click="delete"
                phx-value-id={contact.id}
                data-confirm={"Remove #{contact.name}?"}
                class="rounded p-1 text-base-content/40 hover:text-error"
                title="Remove"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>

            <form
              :if={@editing == contact.id}
              id={"contact-edit-#{contact.id}"}
              phx-submit="update"
              class="space-y-2"
            >
              <input type="hidden" name="contact_id" value={contact.id} />
              <div class="flex flex-wrap gap-2">
                <input
                  type="text"
                  name="name"
                  required
                  value={contact.name}
                  class="input input-bordered input-sm min-w-40 flex-1"
                />
                <input
                  type="text"
                  name="role"
                  value={contact.role}
                  placeholder="Role"
                  class="input input-bordered input-sm min-w-40 flex-1"
                />
                <input
                  type="text"
                  name="department"
                  value={contact.department}
                  placeholder="Department"
                  class="input input-bordered input-sm w-36"
                />
              </div>
              <div class="flex flex-wrap gap-2">
                <input
                  type="email"
                  name="email"
                  value={contact.email}
                  placeholder="Email"
                  class="input input-bordered input-sm min-w-40 flex-1"
                />
                <input
                  type="text"
                  name="phone"
                  value={contact.phone}
                  placeholder="Phone"
                  class="input input-bordered input-sm w-40"
                />
                <button type="submit" class="btn btn-neutral btn-sm">Save</button>
                <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-sm">Cancel</button>
              </div>
            </form>
          </div>

          <p :if={@contacts == []} class="px-4 py-8 text-center text-sm text-base-content/40">
            No contacts yet — add your first cast or crew member above.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
