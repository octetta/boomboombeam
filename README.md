# BoomBoomBeam

BoomBoomBeam is a desktop audio workstation interface built with Elixir, Phoenix LiveView, and a native Zig backend engine (`skred`).

## Prerequisites

To develop or build this project, you need:
1. **Elixir & Erlang/OTP** (v1.17+) - For the frontend web application.
2. **Zig** (v0.13.0+) - To compile the native `skred` audio engine.

## Running in Development

In development, the Elixir backend will look for the `skred_port` binary in your local root directory. 

Before building the audio engine, you must download the pre-compiled `pulp` C library (which contains the core signal processing algorithms) for your platform:
```bash
./download-pulp.sh
```

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
   Now visit [`localhost:4000`](http://localhost:4000) from your browser. 

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
