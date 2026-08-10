defmodule BoomBoomBeam.AudioEngine.Port do
  use GenServer

  require Logger

  @pubsub BoomBoomBeam.PubSub
  @topic "skred_repl"

  @behaviour BoomBoomBeam.AudioEngine

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl BoomBoomBeam.AudioEngine
  def command(cmd_string, opts \\ []) do
    silent = Keyword.get(opts, :silent, false)
    GenServer.cast(__MODULE__, {:command, cmd_string, silent})
  end

  @impl BoomBoomBeam.AudioEngine
  def restart(opts \\ []) do
    GenServer.cast(__MODULE__, {:restart, opts})
  end

  # Server Callbacks

  @impl true
  def init(:ok) do
    port = open_port()
    {:ok, %{port: port}}
  end

  defp open_port() do
    {_os_fam, os_name} = :os.type()
    
    dir = case os_name do
      :nt -> "windows"
      :darwin -> "macos"
      _ -> "linux"
    end
    
    filename = if os_name == :nt, do: "skred_port.exe", else: "skred_port"
    priv_path = Application.app_dir(:boomboombeam, "priv/bin/#{dir}/#{filename}")
    
    executable = if File.exists?(priv_path) do
      priv_path
    else
      Path.join(File.cwd!(), filename)
    end
    
    # Set CWD to priv so that ./sk and ./wav are available directly
    priv_dir = Application.app_dir(:boomboombeam, "priv")

    port = Port.open({:spawn_executable, executable}, [
      :binary,
      {:line, 8192},
      :use_stdio,
      :exit_status,
      {:cd, priv_dir}
    ])
    
    Logger.info("Started Skred audio port (port: #{inspect(port)})")
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:skred_status, :started})
    port
  end

  @impl true
  def handle_cast({:command, cmd_string, silent}, state) do
    msg = "#{cmd_string}\n"
    Port.command(state.port, msg)
    
    unless silent do
      # Broadcast the command itself so the UI knows what was sent
      Phoenix.PubSub.broadcast(@pubsub, @topic, {:skred_cmd, cmd_string})
    end
    
    {:noreply, state}
  end

  @impl true
  def handle_cast({:restart, opts}, state) do
    Logger.info("Restarting Skred audio port with opts: #{inspect(opts)}")
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:skred_status, :restarting})
    # Close the current port
    Port.close(state.port)
    # Open a new one (opts could be passed here later)
    new_port = open_port()
    {:noreply, %{state | port: new_port}}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    # Broadcast output back to any subscribers (like the REPL UI)
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:skred_data, line <> "\n"})
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:noeol, line}}}, %{port: port} = state) do
    # Broadcast output back to any subscribers
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:skred_data, line})
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("Skred Port Exited with status: #{status}")
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:skred_status, {:exited, status}})
    # We could stop here, but let's just let it be handled by a manual restart or supervisor
    {:stop, :port_exited, state}
  end
end
