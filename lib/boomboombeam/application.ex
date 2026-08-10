defmodule BoomBoomBeam.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BoomBoomBeamWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:boomboombeam, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: BoomBoomBeam.PubSub},
      BoomBoomBeam.AudioPort,
      # Start to serve requests, typically the last entry
      BoomBoomBeamWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: BoomBoomBeam.Supervisor]
    result = Supervisor.start_link(children, opts)

    # In Burrito, the release skips the standard `mix release` wrapper that passes `--no-halt`.
    # To prevent the Erlang VM from instantly exiting after boot, we manually set no_halt.
    System.no_halt(true)

    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BoomBoomBeamWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
