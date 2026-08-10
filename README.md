# BoomBoomBeam

BoomBoomBeam is a desktop audio workstation interface built with Elixir, Phoenix LiveView, and a native Zig backend engine (`skred`).

## Prerequisites

To develop or build this project, you need:
1. **Elixir & Erlang/OTP** (v1.17+) - For the frontend web application.
2. **Zig** (v0.13.0+) - To compile the native `skred` audio engine.

## The Three Execution Engines

BoomBoomBeam is designed as a "kitchen-sink" reference architecture to show off how the BEAM can integrate with native audio code (`skred`) in three entirely different topologies:

1. **Local Port (Elixir Managed)**
   The backend spawns the `skred` binary as a child OS process using Erlang Ports. The Erlang VM manages its lifecycle and streams commands via `stdio`. This has minimal latency and zero-config deployment.
   
2. **Browser WASM (Client-Side)**
   Using WebAssembly, the entire audio engine runs locally inside the user's web browser using the Web Audio API. Elixir acts strictly as a WebSocket control plane, pushing commands to the client. This offloads all audio compute from the server.
   
3. **Remote UDP (Distributed)**
   Elixir sends stateful commands over `:gen_udp` to a standalone `skred` server running anywhere on the network. This allows separating the web server from the heavy-compute audio nodes.

You can hot-swap between these three engines at runtime using the dropdown in the UI!

## Running in Development

In development, the Elixir backend will look for the `skred_port` binary in your local root directory. 

Before building the audio engine, you must download the pre-compiled `pulp` C library (which contains the core signal processing algorithms) for your platform:
```bash
./download-pulp.sh
```
This script will also download the WebAssembly (`skred.wasm`) binaries and place them into `/priv/static/assets/skred/` so the frontend can serve them.

### Method 1: Local Port Engine
1. **Build the Audio Engine**:
   ```bash
   cd native/skred_port
   zig build -Doptimize=ReleaseFast
   cp zig-out/bin/skred_port ../../
   cd ../../
   ```

2. **Start the Web Application**:
   ```bash
   mix setup
   mix phx.server
   ```
   Now visit [`localhost:4000`](http://localhost:4000) from your browser and select **Local Port**!

### Method 2: Browser WASM Engine
Simply run `mix phx.server` and select **Browser WASM** from the UI. The Elixir backend will route commands to your browser over WebSockets and play audio client-side. No native Zig compilation required!

### Method 3: Remote UDP Engine
1. Start the standalone `mini-skred` UDP server (which was downloaded by the `download-pulp.sh` script):
   ```bash
   ./run-mini-skred.sh
   ```
2. Run `mix phx.server` in a separate terminal.
3. Select **Remote UDP** from the UI dropdown!


*Note: Since LiveReload requires `inotify-tools` on Linux, you may need to manually refresh (F5) the browser when making UI changes if it's missing on your system.*

## Building Desktop Standalone Distributions

BoomBoomBeam uses [Burrito](https://github.com/burrito-elixir/burrito) to package the entire system (Erlang VM, Phoenix App, and the Zig audio engine) into a single, cross-platform standalone executable that can be zipped and distributed without users needing to install dependencies.

To build the binaries for Windows, macOS, and Linux, simply run:

```bash
./build_releases.sh
```

**What the script does:**
1. Uses Zig's cross-compilation to build the native audio engine for `x86_64-linux`, `x86_64-windows`, and `aarch64-macos`.
2. Places these native binaries into the `priv/bin/` directory so they are bundled into the application.
3. Compiles and minifies the Phoenix frontend assets.
4. Uses Burrito to cross-compile the Elixir app and wrap it all into standalone executables.

When finished, your distributable binaries will be waiting in the `burrito_out/` directory.
