defmodule MoorlandWeb.UserLive.Login do
  use MoorlandWeb, :live_view

  alias Moorland.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-6 py-6 sm:py-10">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">
            {if @current_scope, do: "Confirm it's you", else: "Log in"}
          </h1>
          <p class="mt-1 text-sm text-base-content/60">
            <%= if @current_scope do %>
              Log in again to change sensitive account settings.
            <% else %>
              New here? <.link
                navigate={~p"/users/register"}
                class="font-medium text-base-content underline decoration-base-content/30 underline-offset-2 transition-colors hover:decoration-base-content"
                phx-no-format
              >Create an account</.link>.
            <% end %>
          </p>
        </div>

        <div
          :if={local_mail_adapter?()}
          id="mailbox-hint"
          class="flex gap-3 rounded-lg border border-base-300 bg-base-200/40 px-4 py-3 text-sm"
        >
          <.icon name="hero-inbox" class="mt-0.5 size-4 shrink-0 text-base-content/60" />
          <p class="text-base-content/70">
            Moorland sends no real email. Login links land in <.link
              href="/dev/mailbox"
              class="font-medium text-base-content underline underline-offset-2"
              phx-no-format
            >this computer's mailbox</.link>.
          </p>
        </div>

        <.form
          :let={f}
          for={@form}
          id="login_form_magic"
          action={~p"/users/log-in"}
          phx-submit="submit_magic"
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button class="btn btn-neutral w-full">
            Email me a login link <span aria-hidden="true">→</span>
          </.button>
        </.form>

        <div class="divider text-xs text-base-content/40">or use a password</div>

        <.form
          :let={f}
          for={@form}
          id="login_form_password"
          action={~p"/users/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
            spellcheck="false"
          />
          <.button class="btn btn-neutral w-full" name={@form[:remember_me].name} value="true">
            Log in and stay logged in <span aria-hidden="true">→</span>
          </.button>
          <.button class="btn btn-ghost w-full mt-2 text-base-content/70">
            Log in only this time
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:moorland, Moorland.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
