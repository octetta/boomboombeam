defmodule BoomBoomBeam.AudioEngine.Udp do
  @behaviour BoomBoomBeam.AudioEngine
  use GenServer

  require Logger

  @pubsub BoomBoomBeam.PubSub
  @topic "skred_repl"

  # We define a local UDP port and a remote UDP port
  @remote_ip {127, 0, 0, 1}
  @remote_port 60440

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
    {:ok, socket} = :gen_udp.open(0, [:binary, active: true])
    Logger.info("Started Skred UDP engine port on #{inspect(socket)}")
    
    # Send log1 so the remote mini-skred engine sends command output back to us
    :gen_udp.send(socket, @remote_ip, @remote_port, "log1\n")
    
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:skred_status, :started})
    {:ok, %{socket: socket}}
  end

  @impl true
  def handle_cast({:command, cmd_string, silent}, state) do
    msg = "#{cmd_string}\n"
    
    # Send to remote UDP Skred server
    :gen_udp.send(state.socket, @remote_ip, @remote_port, msg)
    
    unless silent do
      Phoenix.PubSub.broadcast(@pubsub, @topic, {:skred_cmd, cmd_string})
    end
    
    {:noreply, state}
  end

  @impl true
  def handle_cast({:restart, opts}, state) do
    Logger.info("Sending restart signal over UDP with opts: #{inspect(opts)}")
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:skred_status, :restarting})
    
    # Send log1 again in case the remote server was just restarted
    :gen_udp.send(state.socket, @remote_ip, @remote_port, "log1\n")
    
    # Optional: Send a custom restart command if the UDP server supports it
    # :gen_udp.send(state.socket, @remote_ip, @remote_port, "restart\n")
    
    {:noreply, state}
  end

  @impl true
  def handle_info({:udp, _socket, _ip, _port, data}, state) do
    # Receive UDP data back from Skred
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:skred_data, data})
    {:noreply, state}
  end
end
