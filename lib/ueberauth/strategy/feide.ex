defmodule Ueberauth.Strategy.Feide do
  @moduledoc """
  Provides an Ueberauth strategy for authenticating with GitHub.

  ### Setup

  Create an application in Github for you to use.

  Register a new application at: [your github developer page](https://github.com/settings/developers)
  and get the `client_id` and `client_secret`.

  Include the provider in your configuration for Ueberauth;

      config :ueberauth, Ueberauth,
        providers: [
          github: { Ueberauth.Strategy.Github, [] }
        ]

  Then include the configuration for GitHub:

      config :ueberauth, Ueberauth.Strategy.Github.OAuth,
        client_id: System.get_env("GITHUB_CLIENT_ID"),
        client_secret: System.get_env("GITHUB_CLIENT_SECRET")

  If you haven't already, create a pipeline and setup routes for your callback handler

      pipeline :auth do
        Ueberauth.plug "/auth"
      end

      scope "/auth" do
        pipe_through [:browser, :auth]

        get "/:provider/callback", AuthController, :callback
      end

  Create an endpoint for the callback where you will handle the
  `Ueberauth.Auth` struct:

      defmodule MyApp.AuthController do
        use MyApp.Web, :controller

        def callback_phase(%{ assigns: %{ ueberauth_failure: fails } } = conn, _params) do
          # do things with the failure
        end

        def callback_phase(%{ assigns: %{ ueberauth_auth: auth } } = conn, params) do
          # do things with the auth
        end
      end

  You can edit the behaviour of the Strategy by including some options when you
  register your provider.

  To set the `uid_field`:

      config :ueberauth, Ueberauth,
        providers: [
          github: { Ueberauth.Strategy.Github, [uid_field: :email] }
        ]

  Default is `:id`.

  To set the default 'scopes' (permissions):

      config :ueberauth, Ueberauth,
        providers: [
          github: { Ueberauth.Strategy.Github, [default_scope: "user,public_repo"] }
        ]

  Default is empty ("") which "Grants read-only access to public information
  (includes public user profile info, public repository info, and gists)"
  """
  use Ueberauth.Strategy,
    uid_field: :uid,
    default_scope: "",
    send_redirect_uri: true,
    oauth2_module: Ueberauth.Strategy.Feide.OAuth

  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra

  @doc """
  Handles the initial redirect to the github authentication page.

  To customize the scope (permissions) that are requested by github include
  them as part of your url:

      "/auth/github?scope=user,public_repo,gist"
  """

  def handle_request!(conn) do
    opts =
      []
      |> with_scopes(conn)
      |> with_state_param(conn)
      |> with_redirect_uri(conn)
      |> Keyword.update!(:redirect_uri, fn uri ->
        String.replace_prefix(uri, "http://", "https://")
      end)

    module = option(conn, :oauth2_module)
    redirect!(conn, apply(module, :authorize_url!, [opts]))
  end

  @doc """
  Handles the callback from GitHub.

  When there is a failure from Github the failure is included in the
  `ueberauth_failure` struct. Otherwise the information returned from Github is
  returned in the `Ueberauth.Auth` struct.
  """
  def handle_callback!(%Plug.Conn{params: %{"code" => code}} = conn) do
    module = option(conn, :oauth2_module)

    token =
      apply(module, :get_token!, [
        [
          code: code
        ]
      ])

    if token.access_token == nil do
      set_errors!(conn, [
        error(token.other_params["error"], token.other_params["error_description"])
      ])
    else
      fetch_user(conn, token)
    end
  end

  @doc false
  def handle_callback!(conn) do
    set_errors!(conn, [error("missing_code", "No code received")])
  end

  @doc """
  Cleans up the private area of the connection used for passing the raw GitHub
  response around during the callback.
  """
  def handle_cleanup!(conn) do
    conn
    |> put_private(:feide_user, nil)
    |> put_private(:feide_token, nil)
  end

  @doc """
  Fetches the `:uid` field from the GitHub response.

  This defaults to the option `:uid_field` which in-turn defaults to `:id`
  """
  def uid(conn) do
    conn |> option(:uid_field) |> to_string() |> fetch_uid(conn)
  end

  @doc """
  Includes the credentials from the GitHub response.
  """
  def credentials(conn) do
    token = conn.private.feide_token
    scope_string = token.other_params["scope"] || ""
    scopes = String.split(scope_string, ",")

    %Credentials{
      token: token.access_token,
      refresh_token: token.refresh_token,
      expires_at: token.expires_at,
      token_type: token.token_type,
      expires: !!token.expires_at,
      scopes: scopes
    }
  end

  @doc """
  Fetches the fields to populate the info section of the `Ueberauth.Auth`
  struct.
  """
  def info(conn) do
    user = conn.private.feide_user

    %Info{
      name: user["displayName"],
      nickname: user["givenName"],
      email: user["eduPersonPrincipalName"]
    }
  end

  @doc """
  Stores the raw information (including the token) obtained from the GitHub
  callback.
  """
  def extra(conn) do
    %Extra{
      raw_info: %{
        token: conn.private.feide_token,
        user: conn.private.feide_user
      }
    }
  end

  defp fetch_uid(field, conn) do
    conn.private.feide_user[field]
  end

  defp fetch_user(conn, token) do
    conn = put_private(conn, :feide_token, token)
    # Will be better with Elixir 1.3 with/else
    case Ueberauth.Strategy.Feide.OAuth.get(
           token,
           "https://api.dataporten.no/userinfo/v1/userinfo"
         ) do
      {:ok, %OAuth2.Response{status_code: 401, body: _body}} ->
        set_errors!(conn, [error("token", "unauthorized")])

      {:ok, %OAuth2.Response{status_code: _status_code, body: user}} ->
        put_private(conn, :feide_user, user)

      {:error, %OAuth2.Error{reason: reason}} ->
        set_errors!(conn, [error("OAuth2", reason)])

      {:error, %OAuth2.Response{body: %{"message" => reason}}} ->
        set_errors!(conn, [error("OAuth2", reason)])

      {:error, _} ->
        set_errors!(conn, [error("OAuth2", "unknown error")])
    end
  end

  defp option(conn, key) do
    Keyword.get(options(conn), key, Keyword.get(default_options(), key))
  end

  defp with_scopes(opts, conn) do
    scopes = conn.params["scope"] || option(conn, :default_scope)

    opts |> Keyword.put(:scope, scopes)
  end

  defp with_redirect_uri(opts, conn) do
    if option(conn, :send_redirect_uri) do
      opts |> Keyword.put(:redirect_uri, callback_url(conn))
    else
      opts
    end
  end
end
