defmodule BoomBoomBeam.AudioEngine do
  @callback command(cmd_string :: String.t(), opts :: keyword()) :: :ok | {:error, any()}
  @callback restart(opts :: keyword()) :: :ok | {:error, any()}

  @pubsub BoomBoomBeam.PubSub
  @topic "skred_repl"

  def command(cmd_string, opts \\ []) do
    engine().command(cmd_string, opts)
  end

  def restart(opts \\ []) do
    engine().restart(opts)
  end

  def set_volume(voice, volume) do
    command("v#{voice} a#{volume}")
  end

  def set_pitch(voice, pitch) do
    command("v#{voice} f#{pitch}")
  end

  def send_trigger(voice) do
    command("v#{voice} t1")
  end

  def set_engine(engine_module) do
    Agent.update(__MODULE__.State, fn _ -> engine_module end)
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:engine_changed, engine_module})
    
    # Always ensure the new engine knows to send log output back
    command("log1", silent: true)
  end

  def engine() do
    Agent.get(__MODULE__.State, & &1)
  end
end

defmodule BoomBoomBeam.AudioEngine.State do
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> BoomBoomBeam.AudioEngine.Port end, name: __MODULE__)
  end
end
