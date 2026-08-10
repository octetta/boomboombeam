# BoomBoomBeam

BoomBoomBeam is a technical showcase demonstrating how to integrate the [Pulp/Skred](https://github.com/octetta/pulp) audio engine with the BEAM ecosystem. While it features a Phoenix LiveView-based interface for interacting with the engine, it is **not a full audio workstation**—it is simply a reference architecture designed to highlight the incredible flexibility of running native C/Zig audio code alongside Elixir.

## Prerequisites

To develop or build this project locally, you need:
1. **Elixir & Erlang/OTP** (v1.17+) - For the frontend web application.
2. **Zig** (v0.13.0+) - To compile the native `skred` audio engine targets.
3. **mise** (Optional but recommended) - Used in our Makefile for managing toolchains.

## The Three Execution Engines

BoomBoomBeam acts as a "kitchen-sink" integration demo, allowing you to hot-swap between three entirely different audio topologies at runtime directly from the UI dropdown:

1. **Local Port (Elixir Managed)**
   The backend spawns the `skred_port` Zig binary as a child OS process using Erlang Ports. The Erlang VM manages its lifecycle and streams commands via `stdin/stdout`. This offers minimal latency, zero-config deployment, and supports high-bandwidth data dumps (like waveforms).
   
2. **Remote UDP (Distributed)**
   Elixir sends stateful commands over `:gen_udp` to a standalone headless `skred_udp` server running anywhere on your network. This demonstrates how to separate the web server control plane from heavy-compute audio nodes (e.g. running the UI on a cloud server and the audio engine on a Raspberry Pi).
   
3. **Browser WASM (Client-Side)**
   Using WebAssembly, the entire audio engine runs locally inside the user's web browser using the Web Audio API. Elixir acts strictly as a WebSocket control plane, pushing commands to the client. This offloads all audio compute from the server, showcasing infinite multi-tenant scalability.

## Running the Showcase

The project uses a simple `Makefile` to handle downloads and compilation.

### 1. Download Dependencies
Before building the native engines, you must download the pre-compiled `pulp` C library (which contains the core signal processing algorithms) and the WebAssembly blobs:
```bash
make update
```

### 2. Build the Audio Engines
Compile both the standard Erlang Port engine and the headless UDP server:
```bash
make native
make udp
```

### 3. Start the Web Application
Compile the Elixir application and boot the Phoenix server:
```bash
make build
make run
```
Now visit [`localhost:4000`](http://localhost:4000) from your browser!

### Running the Remote UDP Engine
If you want to test the UDP architecture, open a second terminal and boot the headless standalone server:
```bash
./priv/bin/linux/skred_udp
```
Then, switch the UI to **Remote UDP**. You can optionally configure the target IP and Port dynamically from the top bar.

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
