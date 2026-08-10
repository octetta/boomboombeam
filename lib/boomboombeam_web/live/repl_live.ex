defmodule BoomBoomBeamWeb.ReplLive do
  use BoomBoomBeamWeb, :live_view
  
  alias BoomBoomBeam.AudioEngine

  @topic "skred_repl"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(BoomBoomBeam.PubSub, @topic)
      # Query the engine for the current state of Delay Line 1
      AudioEngine.command("DL?1", silent: true)
    end
    
    dl_defaults = %{"s1" => "0", "s2" => "0", "s3" => "0", "s4" => "0", "s5" => "0", "s6" => "0"}
    
    socket = socket
    |> assign(:log, [])
    |> assign(:perf_history, %{
      BoomBoomBeam.AudioEngine.Port => [],
      BoomBoomBeam.AudioEngine.Udp => [],
      BoomBoomBeam.AudioEngine.Wasm => []
    })
    |> assign(form: to_form(%{"command" => ""}))
    |> assign(dl_form: to_form(dl_defaults))
    |> assign(:active_engine, AudioEngine.engine())
    |> assign(:theme, :light)
    |> assign(:wave_buffer, "")
    
    {:ok, socket}
  end

  @impl true
  def handle_info({:engine_changed, engine}, socket) do
    engine_name = case engine do
      BoomBoomBeam.AudioEngine.Port -> "Local Port"
      BoomBoomBeam.AudioEngine.Udp -> "Remote UDP"
      BoomBoomBeam.AudioEngine.Wasm -> "Browser WASM"
    end
    msg = "Switched active engine to #{engine_name}"
    log = [{:status, msg} | socket.assigns.log] |> Enum.take(50)
    {:noreply, assign(socket, active_engine: engine, log: log)}
  end

  @impl true
  def handle_event("wasm_output", %{"data" => data}, socket) do
    # Treat wasm output identically to backend skred output
    send(self(), {:skred_data, data})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:wasm_cmd, cmd}, socket) do
    {:noreply, push_event(socket, "wasm_cmd", %{"cmd" => cmd})}
  end

  @impl true
  def handle_info({:wasm_restart, _}, socket) do
    {:noreply, push_event(socket, "wasm_restart", %{})}
  end

  @impl true
  def handle_event("update_form", %{"command" => _cmd} = params, socket) do
    {:noreply, assign(socket, form: to_form(params))}
  end

  @impl true
  def handle_event("submit_command", %{"command" => command}, socket) do
    cmd = String.trim(command)
    if cmd != "" do
      AudioEngine.command(cmd)
      {:noreply, assign(socket, form: to_form(%{"command" => ""}))}
    else
      {:noreply, assign(socket, form: to_form(%{"command" => ""}))}
    end
  end

  @impl true
  def handle_event("update_dl", params, socket) do
    s1 = params["s1"] || "0"
    s2 = params["s2"] || "0"
    s3 = params["s3"] || "0"
    s4 = params["s4"] || "0"
    s5 = params["s5"] || "0"
    s6 = params["s6"] || "0"
    
    cmd = "DL1,#{s1},#{s2},#{s3},#{s4},#{s5},#{s6}"
    AudioEngine.command(cmd, silent: true)
    
    {:noreply, assign(socket, dl_form: to_form(params))}
  end

  @impl true
  def handle_event("restart", _unsigned_params, socket) do
    AudioEngine.restart()
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_theme", _unsigned_params, socket) do
    new_theme = if socket.assigns.theme == :dark, do: :light, else: :dark
    {:noreply, socket |> assign(:theme, new_theme) |> push_event("save_theme", %{"theme" => to_string(new_theme)})}
  end

  @impl true
  def handle_event("set_theme", %{"theme" => theme_str}, socket) do
    theme = if theme_str == "dark", do: :dark, else: :light
    {:noreply, assign(socket, :theme, theme)}
  end

  @impl true
  def handle_event("fetch_dl", _unsigned_params, socket) do
    AudioEngine.command("DL?1", silent: true)
    {:noreply, socket}
  end

  @impl true
  def handle_event("fetch_perf", _unsigned_params, socket) do
    AudioEngine.command("/a?", silent: true)
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_engine", %{"engine" => engine_str}, socket) do
    engine = case engine_str do
      "port" -> BoomBoomBeam.AudioEngine.Port
      "udp" -> BoomBoomBeam.AudioEngine.Udp
      "wasm" -> BoomBoomBeam.AudioEngine.Wasm
    end
    AudioEngine.set_engine(engine)
    {:noreply, socket}
  end



  @impl true
  def handle_info({:skred_data, data}, socket) do
    lines = data |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    
    socket = Enum.reduce(lines, socket, fn data_str, acc_socket ->
      # Check for async JSON control events
      if String.starts_with?(data_str, "{\"type\":\"skred_event\"") do
        case Jason.decode(data_str) do
          {:ok, event} ->
            IO.inspect(event, label: "SKRED ASYNC EVENT")
            acc_socket
          _ ->
            acc_socket
        end
      else
        acc_socket =
          cond do
            String.starts_with?(data_str, "~WAVE:START") ->
              assign(acc_socket, :wave_buffer, "")
              
            String.starts_with?(data_str, "~WAVE:END") ->
              buffer = acc_socket.assigns.wave_buffer
              try do
                decoded = Base.decode64!(buffer)
                uncompressed = :zlib.uncompress(decoded)
                floats = for <<val::float-little-size(32) <- uncompressed>>, do: val
                push_event(acc_socket, "draw_wave", %{"data" => floats})
              rescue
                e ->
                  IO.inspect(e, label: "Failed to decode/uncompress wave data")
                  acc_socket
              end |> assign(:wave_buffer, "")
              
            String.starts_with?(data_str, "~WAVE:") ->
              chunk = String.trim_leading(data_str, "~WAVE:")
              assign(acc_socket, :wave_buffer, acc_socket.assigns.wave_buffer <> chunk)
              
            acc_socket.assigns.wave_buffer != "" ->
              # Handle lines that were split by Emscripten's internal printf line buffer limits
              assign(acc_socket, :wave_buffer, acc_socket.assigns.wave_buffer <> data_str)
              
            true ->
              acc_socket
          end
        
        acc_socket = 
          if String.starts_with?(String.trim_leading(data_str), "DL1,") do
            dl_block = data_str |> String.trim_leading() |> String.split(" ") |> List.first()
            
            case String.split(dl_block, ",") do
              ["DL1", s1, s2, s3, s4, s5, s6 | _] ->
                assign(acc_socket, dl_form: to_form(%{"s1" => s1, "s2" => s2, "s3" => s3, "s4" => s4, "s5" => s5, "s6" => s6}))
              _ ->
                acc_socket
            end
          else
            acc_socket
          end
    
        acc_socket = 
          if data_str =~ "callback-load:" do
            case Regex.run(~r/callback-load: last ([\d\.]+)% avg ([\d\.]+)% worst ([\d\.]+)%/, data_str) do
              [_, last, avg, worst] ->
                point = %{
                  last: String.to_float(last), 
                  avg: String.to_float(avg), 
                  worst: String.to_float(worst)
                }
                active = acc_socket.assigns.active_engine
                history = Map.update!(acc_socket.assigns.perf_history, active, fn list ->
                  Enum.take([point | list], 30)
                end)
                assign(acc_socket, :perf_history, history)
              _ -> acc_socket
            end
          else
            acc_socket
          end
    
        hide_from_log = String.starts_with?(data_str, "~WAVE:") or acc_socket.assigns.wave_buffer != ""
    
        if hide_from_log do
          acc_socket
        else
          log = [{:output, data_str} | acc_socket.assigns.log] |> Enum.take(50)
          assign(acc_socket, :log, log)
        end
      end
    end)
    
    {:noreply, socket}
  end

  @impl true
  def handle_info({:skred_cmd, cmd}, socket) do
    log = [{:input, cmd} | socket.assigns.log] |> Enum.take(50)
    {:noreply, assign(socket, :log, log)}
  end

  @impl true
  def handle_info({:skred_status, status}, socket) do
    msg = case status do
      :started -> "Audio port started."
      :restarting -> "Restarting audio port..."
      {:exited, code} -> "Audio port exited with code #{code}."
      _ -> inspect(status)
    end
    
    log = [{:status, msg} | socket.assigns.log] |> Enum.take(50)
    {:noreply, assign(socket, :log, log)}
  end

  defp max_perf_val(data) do
    if Enum.empty?(data) do
      2.0
    else
      current_max = data |> Enum.map(&(&1.worst)) |> Enum.max()
      max(current_max, 2.0)
    end
  end

  defp build_points(data, key) do
    if Enum.empty?(data) do
      ""
    else
      max_val = max_perf_val(data)
      count = length(data)
      
      data
      |> Enum.reverse() # Display oldest left, newest right
      |> Enum.with_index()
      |> Enum.map(fn {point, idx} ->
        x = if count > 1, do: idx * (300 / (count - 1)), else: 0
        y = 100 - (min(Map.get(point, key), max_val) / max_val * 80) - 10 # 10px padding
        "#{x},#{y}"
      end)
      |> Enum.join(" ")
    end
  end



  defp engine_name(BoomBoomBeam.AudioEngine.Port), do: "Local Port"
  defp engine_name(BoomBoomBeam.AudioEngine.Udp), do: "Remote UDP"
  defp engine_name(BoomBoomBeam.AudioEngine.Wasm), do: "Browser WASM"

  @impl true
  def render(assigns) do
    ~H"""
    <BoomBoomBeamWeb.Layouts.app flash={@flash} current_scope={%{}}>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ThemeManager">
        export default {
          mounted() {
            const storedTheme = localStorage.getItem("theme");
            if (storedTheme === "dark") {
              this.pushEvent("set_theme", { theme: "dark" });
            } else if (storedTheme === "light") {
              this.pushEvent("set_theme", { theme: "light" });
            }
            this.handleEvent("save_theme", ({ theme }) => {
              localStorage.setItem("theme", theme);
            });
          }
        }
      </script>
      <div id="theme-manager" phx-hook=".ThemeManager"></div>
      <div data-theme={if @theme == :dark, do: "dark", else: "light"}>
      <div class="min-h-screen h-screen bg-slate-100 dark:bg-[#09090b] text-slate-900 dark:text-gray-200 p-4 lg:p-8 flex flex-col font-sans relative overflow-hidden transition-colors duration-500">
        
        <!-- Ambient background gradients -->
        <div class="absolute top-[-10%] left-[-10%] w-[40%] h-[40%] bg-blue-600/10 rounded-full blur-[120px] pointer-events-none"></div>
        <div class="absolute bottom-[-10%] right-[-10%] w-[40%] h-[40%] bg-purple-600/10 rounded-full blur-[120px] pointer-events-none"></div>

        <div id="skred-wasm-container" phx-hook="SkredWasmHook" class="hidden"></div>

        <div class="max-w-[1400px] mx-auto w-full flex-1 flex flex-col space-y-6 relative z-10 min-h-0">
          
          <!-- Header -->
          <div class="flex-none flex items-center justify-between backdrop-blur-md bg-white/60 dark:bg-white/[0.02] border border-slate-200 dark:border-white/5 rounded-2xl p-4 shadow-xl">
            <div class="flex items-center space-x-3">
              <div class="w-3 h-3 rounded-full bg-green-500 shadow-[0_0_10px_rgba(34,197,94,0.6)] animate-pulse"></div>
              <h1 class="text-2xl font-semibold tracking-tight text-slate-800 dark:text-white bg-clip-text">BoomBoomBeam Engine</h1>
            </div>
            
            <div class="flex items-center space-x-4">
              <!-- Engine Selector -->
              <div class="flex items-center space-x-2 border-r border-slate-300 dark:border-white/10 pr-4">
                <span class="text-xs font-mono text-slate-500 dark:text-gray-400 uppercase tracking-wider">Engine:</span>
                <form phx-change="set_engine" class="m-0">
                  <select name="engine" class="bg-white dark:bg-black/40 border border-slate-300 dark:border-white/10 text-slate-900 dark:text-white text-sm rounded-lg focus:ring-blue-500 focus:border-blue-500 block p-1.5 cursor-pointer">
                    <option value="port" selected={@active_engine == BoomBoomBeam.AudioEngine.Port}>Local Port</option>
                    <option value="udp" selected={@active_engine == BoomBoomBeam.AudioEngine.Udp}>Remote UDP</option>
                    <option value="wasm" selected={@active_engine == BoomBoomBeam.AudioEngine.Wasm}>Browser WASM</option>
                  </select>
                </form>
              </div>

              <button phx-click="toggle_theme" class="px-3 py-2 text-lg bg-slate-200 dark:bg-white/5 hover:bg-slate-300 dark:hover:bg-white/10 border border-slate-300 dark:border-white/10 rounded-lg transition-all duration-300">
                <%= if @theme == :dark do %>☀️<% else %>🌙<% end %>
              </button>

              <button phx-click="restart" class="px-5 py-2 text-sm bg-slate-200 dark:bg-white/5 hover:bg-slate-300 dark:hover:bg-white/10 border border-slate-300 dark:border-white/10 text-slate-800 dark:text-gray-300 font-medium rounded-lg transition-all duration-300 hover:shadow-[0_0_15px_rgba(255,255,255,0.05)] flex items-center space-x-2">
                <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" /></svg>
                <span>Restart System</span>
              </button>
            </div>
          </div>

          <!-- Main Layout Grid -->
          <div class="grid grid-cols-1 lg:grid-cols-12 gap-6 flex-1 min-h-0 h-full">
            
            <!-- Left Column: Controls (4/12 width) -->
            <div class="lg:col-span-4 flex flex-col space-y-6 h-full overflow-y-auto pr-2 custom-scrollbar">
              
              <!-- Delay Line Controls -->
              <div class="flex-none backdrop-blur-xl bg-white/60 dark:bg-white/[0.03] rounded-2xl p-5 shadow-2xl border border-slate-200 dark:border-white/[0.05] relative overflow-hidden group">
                <div class="absolute inset-0 bg-gradient-to-br from-blue-500/5 to-transparent opacity-0 group-hover:opacity-100 transition-opacity duration-500"></div>
                <div class="relative z-10">
                  <div class="flex items-center justify-between mb-5">
                    <h2 class="text-sm font-medium tracking-widest text-blue-600 dark:text-blue-400 uppercase">Delay Line 1</h2>
                    <div class="flex items-center space-x-3">
                      <button phx-click="fetch_dl" class="px-2 py-1 text-[10px] uppercase tracking-wider font-semibold bg-blue-500/10 text-blue-600 dark:text-blue-400 border border-blue-500/20 rounded hover:bg-blue-500/20 transition-colors">Update</button>
                      <div class="text-[10px] text-slate-500 dark:text-gray-500 font-mono flex items-center space-x-1.5">
                        <div class="w-1.5 h-1.5 rounded-full bg-blue-500 animate-pulse"></div>
                        <span>Via {engine_name(@active_engine)}</span>
                      </div>
                    </div>
                  </div>
                  
                  <.form for={@dl_form} phx-change="update_dl" class="grid grid-cols-2 gap-x-4 gap-y-6">
                    <div class="space-y-1.5 group/slider">
                      <div class="flex justify-between items-end">
                        <label class="text-[11px] font-medium text-slate-500 dark:text-gray-400 group-hover/slider:text-slate-800 dark:group-hover/slider:text-gray-200 transition-colors">Param 1</label>
                        <span class="text-[10px] text-blue-600 dark:text-blue-400 font-mono">{@dl_form[:s1].value}</span>
                      </div>
                      <input type="range" name="s1" value={@dl_form[:s1].value} min="0" max="7" class="w-full h-1.5 bg-slate-300 dark:bg-gray-800 rounded-lg appearance-none cursor-pointer accent-blue-600 dark:accent-blue-500 hover:accent-blue-500 dark:hover:accent-blue-400 transition-all" />
                    </div>
                    
                    <div class="space-y-1.5 group/slider">
                      <div class="flex justify-between items-end">
                        <label class="text-[11px] font-medium text-slate-500 dark:text-gray-400 group-hover/slider:text-slate-800 dark:group-hover/slider:text-gray-200 transition-colors">Param 2</label>
                        <span class="text-[10px] text-blue-600 dark:text-blue-400 font-mono">{@dl_form[:s2].value}</span>
                      </div>
                      <input type="range" name="s2" value={@dl_form[:s2].value} min="0" max="15" class="w-full h-1.5 bg-slate-300 dark:bg-gray-800 rounded-lg appearance-none cursor-pointer accent-blue-600 dark:accent-blue-500 hover:accent-blue-500 dark:hover:accent-blue-400 transition-all" />
                    </div>
                    
                    <div class="space-y-1.5 group/slider">
                      <div class="flex justify-between items-end">
                        <label class="text-[11px] font-medium text-slate-500 dark:text-gray-400 group-hover/slider:text-slate-800 dark:group-hover/slider:text-gray-200 transition-colors">Param 3</label>
                        <span class="text-[10px] text-blue-600 dark:text-blue-400 font-mono">{@dl_form[:s3].value}</span>
                      </div>
                      <input type="range" name="s3" value={@dl_form[:s3].value} min="0" max="15" class="w-full h-1.5 bg-slate-300 dark:bg-gray-800 rounded-lg appearance-none cursor-pointer accent-blue-600 dark:accent-blue-500 hover:accent-blue-500 dark:hover:accent-blue-400 transition-all" />
                    </div>
                    
                    <div class="space-y-1.5 group/slider">
                      <div class="flex justify-between items-end">
                        <label class="text-[11px] font-medium text-slate-500 dark:text-gray-400 group-hover/slider:text-slate-800 dark:group-hover/slider:text-gray-200 transition-colors">Param 4</label>
                        <span class="text-[10px] text-blue-600 dark:text-blue-400 font-mono">{@dl_form[:s4].value}</span>
                      </div>
                      <input type="range" name="s4" value={@dl_form[:s4].value} min="0" max="31" class="w-full h-1.5 bg-slate-300 dark:bg-gray-800 rounded-lg appearance-none cursor-pointer accent-blue-600 dark:accent-blue-500 hover:accent-blue-500 dark:hover:accent-blue-400 transition-all" />
                    </div>
                    
                    <div class="space-y-1.5 group/slider">
                      <div class="flex justify-between items-end">
                        <label class="text-[11px] font-medium text-slate-500 dark:text-gray-400 group-hover/slider:text-slate-800 dark:group-hover/slider:text-gray-200 transition-colors">Param 5</label>
                        <span class="text-[10px] text-blue-600 dark:text-blue-400 font-mono">{@dl_form[:s5].value}</span>
                      </div>
                      <input type="range" name="s5" value={@dl_form[:s5].value} min="0" max="31" class="w-full h-1.5 bg-slate-300 dark:bg-gray-800 rounded-lg appearance-none cursor-pointer accent-blue-600 dark:accent-blue-500 hover:accent-blue-500 dark:hover:accent-blue-400 transition-all" />
                    </div>
                    
                    <div class="space-y-1.5 group/slider">
                      <div class="flex justify-between items-end">
                        <label class="text-[11px] font-medium text-slate-500 dark:text-gray-400 group-hover/slider:text-slate-800 dark:group-hover/slider:text-gray-200 transition-colors">Param 6</label>
                        <span class="text-[10px] text-blue-600 dark:text-blue-400 font-mono">{@dl_form[:s6].value}</span>
                      </div>
                      <input type="range" name="s6" value={@dl_form[:s6].value} min="0" max="15" class="w-full h-1.5 bg-slate-300 dark:bg-gray-800 rounded-lg appearance-none cursor-pointer accent-blue-600 dark:accent-blue-500 hover:accent-blue-500 dark:hover:accent-blue-400 transition-all" />
                    </div>
                  </.form>
                </div>
              </div>
              
              <!-- Performance Monitor Module -->
              <div class="flex-none backdrop-blur-xl bg-white/60 dark:bg-white/[0.03] rounded-2xl p-5 shadow-2xl border border-slate-200 dark:border-white/[0.05] relative overflow-hidden group">
                <div class="absolute inset-0 bg-gradient-to-br from-purple-500/5 to-transparent opacity-0 group-hover:opacity-100 transition-opacity duration-500"></div>
                <div class="relative z-10">
                  <div class="flex items-center justify-between mb-3">
                    <h2 class="text-sm font-medium tracking-widest text-purple-600 dark:text-purple-400 uppercase">Performance</h2>
                    <div class="flex items-center space-x-3">
                      <button phx-click="fetch_perf" class="px-2 py-1 text-[10px] uppercase tracking-wider font-semibold bg-purple-500/10 text-purple-600 dark:text-purple-400 border border-purple-500/20 rounded hover:bg-purple-500/20 transition-colors">Update</button>
                      <div class="text-[10px] text-slate-500 dark:text-gray-500 font-mono flex items-center space-x-1.5">
                        <div class="w-1.5 h-1.5 rounded-full bg-purple-500 animate-pulse"></div>
                        <span>Via {engine_name(@active_engine)}</span>
                      </div>
                    </div>
                  </div>
                  
                  <% current_perf_data = Map.get(@perf_history, @active_engine, []) %>
                  <div class="relative bg-white dark:bg-black/40 rounded-xl border border-slate-200 dark:border-white/5 h-[120px] overflow-hidden w-full shadow-inner">
                    <!-- Chart Grid -->
                    <div class="absolute inset-0 dark:bg-[linear-gradient(rgba(255,255,255,0.02)_1px,transparent_1px),linear-gradient(90deg,rgba(255,255,255,0.02)_1px,transparent_1px)] bg-[linear-gradient(rgba(0,0,0,0.03)_1px,transparent_1px),linear-gradient(90deg,rgba(0,0,0,0.03)_1px,transparent_1px)] bg-[size:20px_20px]"></div>
                    
                    <!-- SVG Chart -->
                    <svg class="absolute inset-0 w-full h-full" viewBox="0 0 300 100" preserveAspectRatio="none">
                      <!-- Avg Load (Dashed Green) -->
                      <polyline points={build_points(current_perf_data, :avg)} fill="none" stroke="#10b981" stroke-width="1.5" stroke-dasharray="3,3" opacity="0.6" />
                      <!-- Last Load (Solid Purple) -->
                      <polyline points={build_points(current_perf_data, :last)} fill="none" stroke="#a855f7" stroke-width="2" />
                    </svg>

                    <!-- Max Value Label -->
                    <div class="absolute top-1 right-2 text-[9px] font-mono text-slate-400 dark:text-gray-500">
                      {Float.round(max_perf_val(current_perf_data), 1)}% Max
                    </div>
                  </div>

                  <!-- Legend -->
                  <div class="flex justify-between items-center mt-3 text-[10px] font-mono">
                    <div class="flex items-center space-x-2">
                      <div class="w-2 h-2 rounded-full bg-purple-500"></div>
                      <span class="text-slate-500 dark:text-gray-400">LAST <span class="text-purple-600 dark:text-purple-300"><%= if point = List.first(current_perf_data), do: "#{point.last}%", else: "--%" %></span></span>
                    </div>
                    <div class="flex items-center space-x-2">
                      <div class="w-2 h-2 rounded-full bg-green-500"></div>
                      <span class="text-slate-500 dark:text-gray-400">AVG <span class="text-green-600 dark:text-green-300"><%= if point = List.first(current_perf_data), do: "#{point.avg}%", else: "--%" %></span></span>
                    </div>
                  </div>
                </div>
              </div>
              
              <!-- Graphics Monitor Module -->
              <div class="flex-none backdrop-blur-xl bg-white/60 dark:bg-white/[0.03] rounded-2xl p-5 shadow-2xl border border-slate-200 dark:border-white/[0.05] relative overflow-hidden group">
                <div class="absolute inset-0 bg-gradient-to-br from-green-500/5 to-transparent opacity-0 group-hover:opacity-100 transition-opacity duration-500"></div>
                <div class="relative z-10">
                  <div class="flex items-center justify-between mb-3">
                    <h2 class="text-sm font-medium tracking-widest text-green-600 dark:text-green-400 uppercase">Waveform Viewer</h2>
                    <div class="text-[10px] text-slate-500 dark:text-gray-500 font-mono flex items-center space-x-1.5">
                      <div class="w-1.5 h-1.5 rounded-full bg-green-500 animate-pulse"></div>
                      <span>Via {engine_name(@active_engine)}</span>
                    </div>
                  </div>
                  
                  <div class="relative bg-white dark:bg-black/40 rounded-xl border border-slate-200 dark:border-white/5 h-[120px] overflow-hidden w-full shadow-inner flex items-center justify-center">
                    <script :type={Phoenix.LiveView.ColocatedHook} name=".WaveformViewer">
                      export default {
                        mounted() {
                          this.ctx = this.el.getContext('2d');
                          this.handleEvent("draw_wave", ({ data }) => {
                            this.draw(data);
                          });
                        },
                        draw(data) {
                          const w = this.el.width;
                          const h = this.el.height;
                          this.ctx.clearRect(0, 0, w, h);
                          this.ctx.strokeStyle = '#10b981';
                          this.ctx.lineWidth = 2;
                          this.ctx.beginPath();
                          
                          for (let i = 0; i < data.length; i++) {
                            const x = (i / data.length) * w;
                            // Float values are generally -1.0 to 1.0. Map 0 to h/2, +1 to 0, -1 to h
                            const y = (h / 2) - (data[i] * (h / 2));
                            if (i === 0) this.ctx.moveTo(x, y);
                            else this.ctx.lineTo(x, y);
                          }
                          this.ctx.stroke();
                        }
                      }
                    </script>
                    <canvas id="waveform-canvas" phx-hook=".WaveformViewer" class="w-full h-full" width="400" height="120"></canvas>
                  </div>
                </div>
              </div>
            </div>

            <!-- Right Column: REPL Console (8/12 width) -->
            <div class="lg:col-span-8 flex flex-col h-full backdrop-blur-xl bg-white dark:bg-[#0a0a0f] rounded-2xl shadow-2xl border border-slate-200 dark:border-white/[0.05] overflow-hidden">
              <!-- Console Header -->
              <div class="flex-none px-4 py-2 border-b border-slate-200 dark:border-white/[0.05] bg-slate-100 dark:bg-black/20 flex items-center space-x-2">
                <div class="flex space-x-1.5">
                  <div class="w-2.5 h-2.5 rounded-full bg-red-500/80"></div>
                  <div class="w-2.5 h-2.5 rounded-full bg-yellow-500/80"></div>
                  <div class="w-2.5 h-2.5 rounded-full bg-green-500/80"></div>
                </div>
                <div class="text-[10px] text-slate-400 dark:text-gray-500 font-mono ml-2">skred-terminal</div>
              </div>
              
              <!-- Console Output -->
              <div class="flex-1 overflow-y-auto min-h-0 font-mono text-[13px] leading-relaxed p-4 flex flex-col-reverse custom-scrollbar" id="repl-log">
                <%= for {type, line} <- @log do %>
                  <%= case type do %>
                    <% :input -> %>
                      <div class="text-indigo-600 dark:text-indigo-400 mt-1 opacity-90 hover:opacity-100 transition-opacity">
                        <span class="opacity-50 text-indigo-500/50">❯</span> {line}
                      </div>
                    <% :output -> %>
                      <div class="text-slate-600 dark:text-[#a6accd] pl-4 whitespace-pre-wrap selection:bg-indigo-500/30">{String.trim(line)}</div>
                    <% :status -> %>
                      <div class="text-sky-600 dark:text-[#89ddff] italic mt-2 opacity-70 text-xs">
                        // {line}
                      </div>
                  <% end %>
                <% end %>
              </div>
              
              <!-- Console Input -->
              <div class="p-3 bg-slate-50 dark:bg-black/40 border-t border-slate-200 dark:border-white/[0.05]">
                <.form for={@form} id="repl-form" phx-change="update_form" phx-submit="submit_command" class="flex relative items-center">
                  <div class="absolute left-3 text-indigo-500 font-mono text-sm pointer-events-none">❯</div>
                  
                  <script :type={Phoenix.LiveView.ColocatedHook} name=".ReplHistory">
                    export default {
                      mounted() {
                        this.history = [];
                        this.historyIdx = -1;
                        this.el.addEventListener("keydown", e => {
                          if (e.key === "ArrowUp") {
                            e.preventDefault();
                            if (this.historyIdx < this.history.length - 1) {
                              this.historyIdx++;
                              this.el.value = this.history[this.historyIdx];
                              this.el.dispatchEvent(new Event("input", { bubbles: true }));
                            }
                          } else if (e.key === "ArrowDown") {
                            e.preventDefault();
                            if (this.historyIdx > 0) {
                              this.historyIdx--;
                              this.el.value = this.history[this.historyIdx];
                              this.el.dispatchEvent(new Event("input", { bubbles: true }));
                            } else if (this.historyIdx === 0) {
                              this.historyIdx = -1;
                              this.el.value = "";
                              this.el.dispatchEvent(new Event("input", { bubbles: true }));
                            }
                          }
                        });
                        this.el.form.addEventListener("submit", () => {
                          if (this.el.value.trim() !== "") {
                            this.history.unshift(this.el.value.trim());
                          }
                          this.historyIdx = -1;
                        });
                      }
                    }
                  </script>
                  
                  <input 
                    type="text" 
                    name={@form[:command].name}
                    value={@form[:command].value}
                    placeholder="Enter skode command..." 
                    autofocus="autofocus" 
                    autocomplete="off" 
                    phx-hook=".ReplHistory" 
                    id="repl-input" 
                    class="w-full bg-transparent text-slate-800 dark:text-gray-200 border-none outline-none focus:ring-0 focus:outline-none pl-8 py-2 font-mono text-[13px] placeholder-slate-400 dark:placeholder-gray-700" 
                  />
                  <div class="absolute right-3 text-[10px] text-slate-400 dark:text-gray-600 font-mono uppercase tracking-widest pointer-events-none">Enter ↵</div>
                </.form>
              </div>
            </div>
            
          </div>
        </div>
      </div>
      </div>
    </BoomBoomBeamWeb.Layouts.app>
    """
  end
end
