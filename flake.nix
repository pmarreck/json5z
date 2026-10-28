{
	description = "json5z: spec-accurate JSON5 validation in Zig";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
		# Shared benchmark engine behind ./bm and ./mg (performance-profile).
		performance-profiling.url = "github:pmarreck/performance_profiling/ecf713b81a74a51f76719bf9debc44fe23a0b331";
	};

	outputs = { self, nixpkgs, performance-profiling }:
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
			# Zig package dependencies (build.zig.zon), fetched once in a
			# fixed-output derivation so sandboxed builds need no network. Zig
			# 0.16 unpacks packages into ./zig-pkg, which is the output.
			# After changing build.zig.zon, set this to "" and rebuild to learn
			# the new hash.
			zigDepsHash = "sha256-m61evDoe3dBqMt6QMWsR75bFqVYhuJhNGsuMq6pX8Sw=";
			zigDeps = pkgs: pkgs.stdenvNoCC.mkDerivation {
				name = "json5z-zig-deps";
				src = pkgs.lib.fileset.toSource {
					root = ./.;
					fileset = pkgs.lib.fileset.unions [ ./build.zig ./build.zig.zon ];
				};
				nativeBuildInputs = [ pkgs.zig pkgs.cacert ];
				outputHashMode = "recursive";
				outputHashAlgo = "sha256";
				outputHash = zigDepsHash;
				dontConfigure = true;
				buildPhase = ''
					export HOME="$TMPDIR"
					export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
					export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
					export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
					zig build --fetch=all
				'';
				installPhase = "cp -r zig-pkg $out";
				dontFixup = true;
			};
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
						]
						# The engine does not build for x86_64-darwin.
						++ nixpkgs.lib.optional (performance-profiling.packages ? ${system}) performance-profiling.packages.${system}.default;
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
							cp -r ${zigDeps pkgs} zig-pkg
							chmod -R u+w zig-pkg
							zig build test -Dtarget=${zigTarget}
						'';
						installPhase = "touch $out";
					};
				});
		};
}
