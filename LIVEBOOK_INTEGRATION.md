# Skred + Livebook Integration Guide

This document serves as a reference for integrating the Pulp/Skred audio engine into [Elixir Livebook](https://livebook.dev/). Since BoomBoomBeam already demonstrates the core multi-engine concepts, you can easily port the UDP and WASM execution models directly into interactive Livebook cells using `Kino`.

## 1. Remote UDP (Server-Side Execution)

The simplest way to control Skred from Livebook is by running the standalone UDP server locally on your machine (or network) and sending commands to it from a standard Elixir cell.

### Prerequisites
Run the headless UDP server compiled from BoomBoomBeam:
```bash
./priv/bin/linux/skred_udp
```
*(This listens on port `60440` by default).*

### Livebook Cell Implementation
You don't need a GenServer for simple commands in Livebook. You can open a UDP socket and fire commands statelessly:

```elixir
# In a Livebook Cell:
{:ok, socket} = :gen_udp.open(0, [:binary, active: false])
target = {{127, 0, 0, 1}, 60440}

# Define a helper function
send_cmd = fn cmd -> 
  :gen_udp.send(socket, elem(target, 0), elem(target, 1), "#{cmd}\n")
end

# Trigger a sound!
send_cmd.("M120")
send_cmd.("DL1,440,0.5,2,1")
send_cmd.("T1,1")
```
*Reference BoomBoomBeam implementation:* `lib/boomboombeam/audio_engine_udp.ex`

## 2. Browser WASM (Client-Side Execution with Kino)

To run the audio engine natively inside the browser viewing the Livebook (zero server compute), you can leverage `Kino.JS` and `Kino.JS.Live`. This allows Livebook to push Elixir state changes down to the browser's Web Audio API.

### Prerequisites
You need the compiled WebAssembly artifacts:
- `skred.wasm`
- `skred.js` (the Emscripten glue code)

### Livebook Cell Implementation
You will create a custom Kino component that embeds the JS logic directly in the notebook:

```elixir
defmodule SkredKino do
  use Kino.JS
  use Kino.JS.Live

  def new() do
    Kino.JS.Live.new(__MODULE__, "")
  end

  # Send a command from Elixir down to the browser
  def command(kino, cmd) do
    Kino.JS.Live.cast(kino, {:skred_cmd, cmd})
  end

  @impl true
  def init(state, ctx) do
    {:ok, assign(ctx, state: state)}
  end

  @impl true
  def handle_cast({:skred_cmd, cmd}, ctx) do
    {:noreply, ctx |> broadcast_event("execute_cmd", %{"cmd" => cmd})}
  end

  asset "main.js" do
    """
    export function init(ctx, data) {
      // 1. Initialize Emscripten Module
      // (You must serve skred.wasm locally or from a CDN)
      
      // 2. Setup AudioWorklet
      const audioCtx = new (window.AudioContext || window.webkitAudioContext)();
      
      // 3. Listen for commands from Elixir
      ctx.handleEvent("execute_cmd", ({ cmd }) => {
        if (window.skred_command) {
           window.skred_command(cmd);
        }
      });
      
      ctx.root.innerHTML = `<div style="padding: 10px; background: #eee; border-radius: 5px;">Skred WASM Engine Ready</div>`;
    }
    """
  end
end
```

### Usage in Notebook
```elixir
# Mount the UI component
kino = SkredKino.new()
Kino.render(kino)

# Send commands to the browser's audio engine
SkredKino.command(kino, "DL2,880,0.2,1,1")
SkredKino.command(kino, "T2,1")
```
*Reference BoomBoomBeam implementation:* `assets/js/app.js` (for the AudioWorklet initialization) and `lib/boomboombeam_web/live/repl_live.ex` (for `push_event` websocket bridging).

## General Tips for Livebook
- **State Management**: If you are generating complex generative sequences, use `Kino.JS.Live` as a stateful process to hold sequence data, and use `Process.send_after` to create a tick-based sequencer entirely in Elixir, piping the output to the UDP or WASM sink.
- **Waveform Visualization**: The `-wave` meta-command relies on local stdout piping. Over UDP, it will not route back to Livebook. If you use WASM, you can intercept the `console.log` base64 dumps in JS and use HTML5 Canvas to render the waveform directly in the Kino output cell!
