defmodule BoomBoomBeam.AudioEngine.Udp do
  @behaviour BoomBoomBeam.AudioEngine
  use GenServer

  require Logger

  @pubsub BoomBoomBeam.PubSub
  @topic "skred_repl"

  # Default remote UDP port
  @default_remote_ip {127, 0, 0, 1}
  @default_remote_port 60440

  # Client API
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def set_target(ip_string, port) when is_binary(ip_string) and is_integer(port) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip_tuple} ->
        GenServer.cast(__MODULE__, {:set_target, ip_tuple, port})
      {:error, _} ->
        Logger.error("Invalid IP address: #{ip_string}")
    end
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
    {:ok, socket} = :gen_udp.open(0, [:binary, active: true])
    Logger.info("Started Skred UDP engine port on #{inspect(socket)}")
    
    # Send log1 so the remote mini-skred engine sends command output back to us
    :gen_udp.send(socket, @default_remote_ip, @default_remote_port, "log1\n")
    
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:skred_status, :started})
    {:ok, %{socket: socket, remote_ip: @default_remote_ip, remote_port: @default_remote_port}}
  end

  @impl true
  def handle_cast({:command, cmd_string, silent}, state) do
    msg = "#{cmd_string}\n"
    
    # Send to remote UDP Skred server
    :gen_udp.send(state.socket, state.remote_ip, state.remote_port, msg)
    
    unless silent do
      Phoenix.PubSub.broadcast(@pubsub, @topic, {:skred_cmd, cmd_string})
    end
    
    {:noreply, state}
  end

  @impl true
  def handle_cast({:restart, opts}, state) do
    Logger.info("Sending restart signal over UDP with opts: #{inspect(opts)}")
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:skred_status, :restarting})
    
    # Send -restart to restart the engine internally if it supports it
    :gen_udp.send(state.socket, state.remote_ip, state.remote_port, "-restart\n")
    # Send log1 again in case the remote server was just restarted
    :gen_udp.send(state.socket, state.remote_ip, state.remote_port, "log1\n")
    
    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_target, ip_tuple, port}, state) do
    Logger.info("UDP Engine target set to #{:inet.ntoa(ip_tuple)}:#{port}")
    # Immediately send log1 to the new target
    :gen_udp.send(state.socket, ip_tuple, port, "log1\n")
    {:noreply, %{state | remote_ip: ip_tuple, remote_port: port}}
  end

  @impl true
  def handle_info({:udp, _socket, _ip, _port, data}, state) do
    # Receive UDP data back from Skred
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:skred_data, data})
    {:noreply, state}
  end
end
