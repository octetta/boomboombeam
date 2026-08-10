.PHONY: all deps build run clean native help

all: deps build native

help:
	@echo "Available targets:"
	@echo "  make deps    - Fetch Mix dependencies"
	@echo "  make native  - Build the Zig skred_port native executable"
	@echo "  make udp     - Build the standalone Zig skred_udp server"
	@echo "  make build   - Build Elixir app and Phoenix assets"
	@echo "  make run     - Run the Phoenix development server (interactive)"
	@echo "  make clean   - Clean build artifacts (priv/bin, _build, burrito_out)"
	@echo "  make release - Build the Burrito standalone executables"
	@echo "  make update  - Download latest Skred engine binaries via script"

deps:
	MIX_ENV=prod mise exec -- mix deps.get

native:
	mkdir -p priv/bin/linux
	cd native/skred_port && mise exec -- zig build-exe main.zig -I ../../clib/pulp/include ../../clib/pulp/lib64/libapi.a -lasound -lm -lc -O ReleaseFast --name skred_port
	rm -f priv/bin/linux/skred_port
	cp native/skred_port/skred_port priv/bin/linux/

udp:
	mkdir -p priv/bin/linux
	cd native/skred_udp && mise exec -- zig build-exe main.zig -I ../../clib/pulp/include ../../clib/pulp/lib64/libapi.a -lasound -lm -lc -O ReleaseFast --name skred_udp
	rm -f priv/bin/linux/skred_udp
	cp native/skred_udp/skred_udp priv/bin/linux/

update:
	./download-pulp.sh

build: deps
	MIX_ENV=prod mise exec -- mix compile
	MIX_ENV=prod mise exec -- mix assets.deploy

run:
	mise exec -- iex -S mix phx.server

release: update native build
	MIX_ENV=prod mise exec -- mix release --overwrite

clean:
	rm -rf priv/bin/linux/skred_port priv/bin/linux/skred_udp
	rm -rf _build
	rm -rf burrito_out
	cd native/skred_port && rm -rf .zig-cache skred_port skred_port.o
	cd native/skred_udp && rm -rf .zig-cache skred_udp skred_udp.o

