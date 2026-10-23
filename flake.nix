{
	description = "json5z: spec-accurate JSON5 validation in Zig";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
	};

	outputs = { self, nixpkgs }:
		let
			systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
			forAllSystems = nixpkgs.lib.genAttrs systems;
			# Reference JSON5 implementation for differential fuzzing (npm json5,
			# pinned by its published sha512).
			json5Reference = pkgs: pkgs.runCommand "json5-reference-2.2.3" {
				src = pkgs.fetchurl {
					url = "https://registry.npmjs.org/json5/-/json5-2.2.3.tgz";
					hash = "sha512-XmOWe7eyHYH14cLdVPoyg+GOH3rYX++KpzrylJwSW98t3Nk+U8XOl8FWKOgwtzdb8lXGf6zYwDUzeHMWfxasyg==";
				};
			} ''
				mkdir -p $out
				tar xzf $src -C $out --strip-components=1
			'';
		in {
			devShells = forAllSystems (system:
				let
					pkgs = import nixpkgs { inherit system; };
				in {
					default = pkgs.mkShell {
						packages = with pkgs; [
							zig
							git
							luajit
							nodejs
						];
						JSON5_REFERENCE = json5Reference pkgs;
					};
				});

			# `nix flake check` runs `zig build test` inside the Nix sandbox.
			checks = forAllSystems (system:
				let
					pkgs = import nixpkgs { inherit system; };
					# Zig bundles musl, so targeting *-linux-musl needs no system libc
					# and builds + runs fully self-contained inside the Nix sandbox.
					# Static musl binaries execute fine on the glibc build host.
					# Darwin uses the native toolchain.
					zigTarget =
						if system == "x86_64-linux" then "x86_64-linux-musl"
						else if system == "aarch64-linux" then "aarch64-linux-musl"
						else "native";
				in {
					tests = pkgs.stdenvNoCC.mkDerivation {
						name = "json5z-tests";
						src = ./.;
						nativeBuildInputs = [ pkgs.zig ];
						dontConfigure = true;
						buildPhase = ''
							# Zig needs writable cache dirs; the sandbox $HOME is read-only.
							export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
							export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
							# Nix's stdenv flags can break Zig's own linker invocation.
							unset NIX_CFLAGS_COMPILE NIX_LDFLAGS
							zig build test -Dtarget=${zigTarget}
						'';
						installPhase = "touch $out";
					};
				});
		};
}
