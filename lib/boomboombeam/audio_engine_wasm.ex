defmodule BoomBoomBeam.AudioEngine.Wasm do
  @behaviour BoomBoomBeam.AudioEngine

  @pubsub BoomBoomBeam.PubSub
  @topic "skred_repl"

  @impl true
  def command(cmd_string, opts \\ []) do
    silent = Keyword.get(opts, :silent, false)
    unless silent do
      Phoenix.PubSub.broadcast(@pubsub, @topic, {:skred_cmd, cmd_string})
    end
    # We also need a specific message for WASM to execute the command directly
    # since it won't be sent to a backend port/udp process.
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:wasm_cmd, cmd_string})
    :ok
  end

  @impl true
  def restart(opts \\ []) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:skred_status, :restarting})
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:wasm_restart, opts})
    :ok
  end
end
