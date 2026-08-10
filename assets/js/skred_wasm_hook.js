export const SkredWasmHook = {
  mounted() {
    this.wasmLoaded = false;
    this.wasmModule = null;

    const self = this;

    // Define the Module object for Emscripten before loading the script
    window.Module = {
      locateFile: function(path, scriptDirectory) {
        if (path === 'skred_api.wasm') {
          return '/assets/skred/skred_api.wasm';
        }
        return scriptDirectory + path;
      },
      print: (function() {
        return function(text) {
          if (typeof window.skredPrintBuffer === 'undefined') window.skredPrintBuffer = "";
          window.skredPrintBuffer += text + "\n";
        };
      })(),
      printErr: function(text) {
        console.error("[Skred WASM Error]", text);
      },
      onRuntimeInitialized: () => {
        this.wasmLoaded = true;
        this.wasmModule = window.Module;
        
        console.log("Skred WASM Engine Loaded! Starting...");
        this.wasmModule.ccall('skred_start', 'void', [], []);
      }
    };

    // Dynamically load the skred API script
    const script = document.createElement("script");
    script.src = "/assets/skred/skred_api.js";
    document.body.appendChild(script);

    // Listen for commands pushed from the LiveView server
    this.handleEvent("wasm_cmd", ({ cmd }) => {
      if (this.wasmLoaded) {
        window.skredPrintBuffer = "";
        
        if (cmd.startsWith("-wave ")) {
            const waveIdx = parseInt(cmd.substring(6).trim(), 10);
            if (!isNaN(waveIdx)) {
                this.wasmModule.ccall('skred_dump_wave_base64', 'void', ['number'], [waveIdx]);
            }
            if (window.skredPrintBuffer !== "") {
                this.pushEvent("wasm_output", { data: window.skredPrintBuffer });
            }
            return;
        }
        
        this.wasmModule.ccall('skred_command', 'void', ['string'], [cmd]);
        
        // Fetch log output using the correct API call
        const ptr = this.wasmModule._skred_log();
        if (ptr) {
          const log = this.wasmModule.UTF8ToString(ptr);
          if (log !== "") {
             window.skredPrintBuffer += log;
          }
        }
        
        if (window.skredPrintBuffer !== "") {
            this.pushEvent("wasm_output", { data: window.skredPrintBuffer });
        }
      } else {
        console.warn("WASM engine not ready yet, dropping command:", cmd);
      }
    });

    this.handleEvent("wasm_restart", () => {
      if (this.wasmLoaded) {
        this.wasmModule.ccall('skred_stop', 'void', [], []);
        setTimeout(() => {
          this.wasmModule.ccall('skred_start', 'void', [], []);
        }, 100);
      }
    });
  },
  destroyed() {
    if (this.wasmLoaded && this.wasmModule) {
      this.wasmModule.ccall('skred_stop', 'void', [], []);
    }
  }
};
