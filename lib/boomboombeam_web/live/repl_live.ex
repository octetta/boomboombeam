defmodule BoomBoomBeamWeb.ReplLive do
  use BoomBoomBeamWeb, :live_view
  
  alias BoomBoomBeam.AudioPort

  @topic "skred_repl"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(BoomBoomBeam.PubSub, @topic)
      # Query the engine for the current state of Delay Line 1
      AudioPort.command("DL?1", silent: true)
      
      # Poll performance metrics every 2 seconds
      :timer.send_interval(2000, self(), :poll_perf)
    end
    
    dl_defaults = %{"s1" => "0", "s2" => "0", "s3" => "0", "s4" => "0", "s5" => "0", "s6" => "0"}
    
    socket = socket
    |> assign(:log, [])
    |> assign(:perf_data, [])
    |> assign(form: to_form(%{"command" => ""}))
    |> assign(dl_form: to_form(dl_defaults))
    
    {:ok, socket}
  end

  @impl true
  def handle_event("update_form", %{"command" => _cmd} = params, socket) do
    {:noreply, assign(socket, form: to_form(params))}
  end

  @impl true
  def handle_event("submit_command", %{"command" => command}, socket) do
    if String.trim(command) != "" do
      AudioPort.command(command)
    end
    
    {:noreply, assign(socket, form: to_form(%{"command" => ""}))}
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
    AudioPort.command(cmd, silent: true)
    
    {:noreply, assign(socket, dl_form: to_form(params))}
  end

  @impl true
  def handle_event("restart", _unsigned_params, socket) do
    AudioPort.restart()
    {:noreply, socket}
  end

  @impl true
  def handle_info(:poll_perf, socket) do
    AudioPort.command("/a?", silent: true)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:skred_data, data}, socket) do
    data_str = String.trim(data)
    
    # Check for async JSON control events
    if String.starts_with?(data_str, "{\"type\":\"skred_event\"") do
      case Jason.decode(data_str) do
        {:ok, event} ->
          # We can handle the event here (e.g. pattern boundaries, voice triggers)
          # For now, just print it to the console or ignore it
          IO.inspect(event, label: "SKRED ASYNC EVENT")
          {:noreply, socket}
        _ ->
          {:noreply, socket}
      end
    else
      # Try to parse state updates from the engine (e.g. DL1 response)
      # The response can look like: "DL1,0,0,0,0,0,0 DD0,0 DF0 DP0 DG0,0"
      socket = 
        if String.starts_with?(String.trim_leading(data), "DL1,") do
          dl_block = data |> String.trim_leading() |> String.split(" ") |> List.first()
          
          case String.split(dl_block, ",") do
            ["DL1", s1, s2, s3, s4, s5, s6 | _] ->
              assign(socket, dl_form: to_form(%{"s1" => s1, "s2" => s2, "s3" => s3, "s4" => s4, "s5" => s5, "s6" => s6}))
            _ ->
              socket
          end
        else
          socket
        end
  
      # Extract performance data
      socket = 
        if data_str =~ "callback-load:" do
          case Regex.run(~r/callback-load: last ([\d\.]+)% avg ([\d\.]+)% worst ([\d\.]+)%/, data_str) do
            [_, last, avg, worst] ->
              point = %{
                last: String.to_float(last), 
                avg: String.to_float(avg), 
                worst: String.to_float(worst)
              }
              # Keep last 30 points (1 minute of data at 2s intervals)
              assign(socket, :perf_data, Enum.take([point | socket.assigns.perf_data], 30))
            _ -> socket
          end
        else
          socket
        end
  
      # Filter /a? spam out of the REPL log
      hide_from_log = data_str =~ "# audio:" or 
                      data_str =~ "out: [" or 
                      data_str =~ "in: [" or 
                      data_str =~ "rate: " or 
                      data_str =~ "device-buffer:" or 
                      data_str =~ "delay:" or 
                      data_str =~ "perf:" or 
                      data_str =~ "callbacks: " or 
                      data_str =~ "callback-ms: " or 
                      data_str =~ "callback-load: " or
                      data_str =~ "suspected-glitches: " or
                      data_str =~ "output: " or
                      data_str =~ "callback-frames: "
  
      if hide_from_log do
        {:noreply, socket}
      else
        log = [{:output, data} | socket.assigns.log] |> Enum.take(50)
        {:noreply, assign(socket, :log, log)}
      end
    end
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



  @impl true
  def render(assigns) do
    ~H"""
    <BoomBoomBeamWeb.Layouts.app flash={@flash} current_scope={%{}}>
      <div class="min-h-screen h-screen bg-[#09090b] text-gray-200 p-4 lg:p-8 flex flex-col font-sans relative overflow-hidden">
        
        <!-- Ambient background gradients -->
        <div class="absolute top-[-10%] left-[-10%] w-[40%] h-[40%] bg-blue-600/10 rounded-full blur-[120px] pointer-events-none"></div>
        <div class="absolute bottom-[-10%] right-[-10%] w-[40%] h-[40%] bg-purple-600/10 rounded-full blur-[120px] pointer-events-none"></div>

        <div class="max-w-[1400px] mx-auto w-full flex-1 flex flex-col space-y-6 relative z-10 min-h-0">
          
          <!-- Header -->
          <div class="flex-none flex items-center justify-between backdrop-blur-md bg-white/[0.02] border border-white/5 rounded-2xl p-4 shadow-xl">
            <div class="flex items-center space-x-3">
              <div class="w-3 h-3 rounded-full bg-green-500 shadow-[0_0_10px_rgba(34,197,94,0.6)] animate-pulse"></div>
              <h1 class="text-2xl font-semibold tracking-tight text-white bg-clip-text text-transparent bg-gradient-to-r from-white to-gray-400">BoomBoomBeam Engine</h1>
            </div>
            <button phx-click="restart" class="px-5 py-2 text-sm bg-white/5 hover:bg-white/10 border border-white/10 text-gray-300 font-medium rounded-lg transition-all duration-300 hover:shadow-[0_0_15px_rgba(255,255,255,0.05)] hover:text-white flex items-center space-x-2">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" /></svg>
              <span>Restart System</span>
            </button>
          </div>

          <!-- Main Layout Grid -->
          <div class="grid grid-cols-1 lg:grid-cols-12 gap-6 flex-1 min-h-0 h-full">
            
            <!-- Left Column: Controls (4/12 width) -->
            <div class="lg:col-span-4 flex flex-col space-y-6 h-full overflow-y-auto pr-2 custom-scrollbar">
              
              <!-- Delay Line Controls -->
              <div class="flex-none backdrop-blur-xl bg-white/[0.03] rounded-2xl p-5 shadow-2xl border border-white/[0.05] relative overflow-hidden group">
                <div class="absolute inset-0 bg-gradient-to-br from-blue-500/5 to-transparent opacity-0 group-hover:opacity-100 transition-opacity duration-500"></div>
                <div class="relative z-10">
                  <div class="flex items-center justify-between mb-5">
                    <h2 class="text-sm font-medium tracking-widest text-blue-400 uppercase">Delay Line 1</h2>
                    <div class="text-[10px] text-gray-500 font-mono">DL1</div>
                  </div>
                  
                  <.form for={@dl_form} phx-change="update_dl" class="grid grid-cols-2 gap-x-4 gap-y-6">
                    <div class="space-y-1.5 group/slider">
                      <div class="flex justify-between items-end">
                        <label class="text-[11px] font-medium text-gray-400 group-hover/slider:text-gray-200 transition-colors">Param 1</label>
                        <span class="text-[10px] text-blue-400 font-mono">{@dl_form[:s1].value}</span>
                      </div>
                      <input type="range" name="s1" value={@dl_form[:s1].value} min="0" max="7" class="w-full h-1.5 bg-gray-800 rounded-lg appearance-none cursor-pointer accent-blue-500 hover:accent-blue-400 transition-all" />
                    </div>
                    
                    <div class="space-y-1.5 group/slider">
                      <div class="flex justify-between items-end">
                        <label class="text-[11px] font-medium text-gray-400 group-hover/slider:text-gray-200 transition-colors">Param 2</label>
                        <span class="text-[10px] text-blue-400 font-mono">{@dl_form[:s2].value}</span>
                      </div>
                      <input type="range" name="s2" value={@dl_form[:s2].value} min="0" max="15" class="w-full h-1.5 bg-gray-800 rounded-lg appearance-none cursor-pointer accent-blue-500 hover:accent-blue-400 transition-all" />
                    </div>
                    
                    <div class="space-y-1.5 group/slider">
                      <div class="flex justify-between items-end">
                        <label class="text-[11px] font-medium text-gray-400 group-hover/slider:text-gray-200 transition-colors">Param 3</label>
                        <span class="text-[10px] text-blue-400 font-mono">{@dl_form[:s3].value}</span>
                      </div>
                      <input type="range" name="s3" value={@dl_form[:s3].value} min="0" max="15" class="w-full h-1.5 bg-gray-800 rounded-lg appearance-none cursor-pointer accent-blue-500 hover:accent-blue-400 transition-all" />
                    </div>
                    
                    <div class="space-y-1.5 group/slider">
                      <div class="flex justify-between items-end">
                        <label class="text-[11px] font-medium text-gray-400 group-hover/slider:text-gray-200 transition-colors">Param 4</label>
                        <span class="text-[10px] text-blue-400 font-mono">{@dl_form[:s4].value}</span>
                      </div>
                      <input type="range" name="s4" value={@dl_form[:s4].value} min="0" max="31" class="w-full h-1.5 bg-gray-800 rounded-lg appearance-none cursor-pointer accent-blue-500 hover:accent-blue-400 transition-all" />
                    </div>
                    
                    <div class="space-y-1.5 group/slider">
                      <div class="flex justify-between items-end">
                        <label class="text-[11px] font-medium text-gray-400 group-hover/slider:text-gray-200 transition-colors">Param 5</label>
                        <span class="text-[10px] text-blue-400 font-mono">{@dl_form[:s5].value}</span>
                      </div>
                      <input type="range" name="s5" value={@dl_form[:s5].value} min="0" max="31" class="w-full h-1.5 bg-gray-800 rounded-lg appearance-none cursor-pointer accent-blue-500 hover:accent-blue-400 transition-all" />
                    </div>
                    
                    <div class="space-y-1.5 group/slider">
                      <div class="flex justify-between items-end">
                        <label class="text-[11px] font-medium text-gray-400 group-hover/slider:text-gray-200 transition-colors">Param 6</label>
                        <span class="text-[10px] text-blue-400 font-mono">{@dl_form[:s6].value}</span>
                      </div>
                      <input type="range" name="s6" value={@dl_form[:s6].value} min="0" max="15" class="w-full h-1.5 bg-gray-800 rounded-lg appearance-none cursor-pointer accent-blue-500 hover:accent-blue-400 transition-all" />
                    </div>
                  </.form>
                </div>
              </div>
              
              <!-- Performance Monitor Module -->
              <div class="flex-none backdrop-blur-xl bg-white/[0.03] rounded-2xl p-5 shadow-2xl border border-white/[0.05] relative overflow-hidden group">
                <div class="absolute inset-0 bg-gradient-to-br from-purple-500/5 to-transparent opacity-0 group-hover:opacity-100 transition-opacity duration-500"></div>
                <div class="relative z-10">
                  <div class="flex items-center justify-between mb-3">
                    <h2 class="text-sm font-medium tracking-widest text-purple-400 uppercase">Performance</h2>
                    <div class="text-[10px] text-gray-500 font-mono">CPU Load</div>
                  </div>
                  
                  <div class="relative bg-black/40 rounded-xl border border-white/5 h-[120px] overflow-hidden w-full">
                    <!-- Chart Grid -->
                    <div class="absolute inset-0 bg-[linear-gradient(rgba(255,255,255,0.02)_1px,transparent_1px),linear-gradient(90deg,rgba(255,255,255,0.02)_1px,transparent_1px)] bg-[size:20px_20px]"></div>
                    
                    <!-- SVG Chart -->
                    <svg class="absolute inset-0 w-full h-full" viewBox="0 0 300 100" preserveAspectRatio="none">
                      <!-- Avg Load (Dashed Green) -->
                      <polyline points={build_points(@perf_data, :avg)} fill="none" stroke="#10b981" stroke-width="1.5" stroke-dasharray="3,3" opacity="0.6" />
                      <!-- Last Load (Solid Purple) -->
                      <polyline points={build_points(@perf_data, :last)} fill="none" stroke="#a855f7" stroke-width="2" />
                    </svg>

                    <!-- Max Value Label -->
                    <div class="absolute top-1 right-2 text-[9px] font-mono text-gray-500">
                      {Float.round(max_perf_val(@perf_data), 1)}% Max
                    </div>
                  </div>

                  <!-- Legend -->
                  <div class="flex justify-between items-center mt-3 text-[10px] font-mono">
                    <div class="flex items-center space-x-2">
                      <div class="w-2 h-2 rounded-full bg-purple-500"></div>
                      <span class="text-gray-400">LAST <span class="text-purple-300"><%= if point = List.first(@perf_data), do: "#{point.last}%", else: "--%" %></span></span>
                    </div>
                    <div class="flex items-center space-x-2">
                      <div class="w-2 h-2 rounded-full bg-green-500"></div>
                      <span class="text-gray-400">AVG <span class="text-green-300"><%= if point = List.first(@perf_data), do: "#{point.avg}%", else: "--%" %></span></span>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <!-- Right Column: REPL Console (8/12 width) -->
            <div class="lg:col-span-8 flex flex-col h-full backdrop-blur-xl bg-[#0a0a0f] rounded-2xl shadow-2xl border border-white/[0.05] overflow-hidden">
              <!-- Console Header -->
              <div class="flex-none px-4 py-2 border-b border-white/[0.05] bg-black/20 flex items-center space-x-2">
                <div class="flex space-x-1.5">
                  <div class="w-2.5 h-2.5 rounded-full bg-red-500/80"></div>
                  <div class="w-2.5 h-2.5 rounded-full bg-yellow-500/80"></div>
                  <div class="w-2.5 h-2.5 rounded-full bg-green-500/80"></div>
                </div>
                <div class="text-[10px] text-gray-500 font-mono ml-2">skred-terminal</div>
              </div>
              
              <!-- Console Output -->
              <div class="flex-1 overflow-y-auto min-h-0 font-mono text-[13px] leading-relaxed p-4 flex flex-col-reverse custom-scrollbar" id="repl-log">
                <%= for {type, line} <- @log do %>
                  <%= case type do %>
                    <% :input -> %>
                      <div class="text-indigo-400 mt-1 opacity-90 hover:opacity-100 transition-opacity">
                        <span class="opacity-50 text-indigo-500/50">❯</span> {line}
                      </div>
                    <% :output -> %>
                      <div class="text-[#a6accd] pl-4 whitespace-pre-wrap selection:bg-indigo-500/30">{String.trim(line)}</div>
                    <% :status -> %>
                      <div class="text-[#89ddff] italic mt-2 opacity-70 text-xs">
                        // {line}
                      </div>
                  <% end %>
                <% end %>
              </div>
              
              <!-- Console Input -->
              <div class="p-3 bg-black/40 border-t border-white/[0.05]">
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
                    class="w-full bg-transparent text-gray-200 border-none outline-none focus:ring-0 focus:outline-none pl-8 py-2 font-mono text-[13px] placeholder-gray-700" 
                  />
                  <div class="absolute right-3 text-[10px] text-gray-600 font-mono uppercase tracking-widest pointer-events-none">Enter ↵</div>
                </.form>
              </div>
            </div>
            
          </div>
        </div>
      </div>
    </BoomBoomBeamWeb.Layouts.app>
    """
  end
end
