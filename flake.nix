{
  description = "UART on a Lattice iCEstick, written in Wiz's HDL and built with grail";

  inputs = {
    # The Wiz toolchain (wiz, grail, the standard library). flake.lock pins the commit;
    # `wiz-toolchain` names the same commit for tower users.
    wiz.url = "github:badly-drawn-wizards/wiz";
    # The same nixpkgs as the toolchain, so its binaries are shared.
    nixpkgs.follows = "wiz/nixpkgs";
  };

  outputs = { self, nixpkgs, wiz }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
    in {
      devShells = forAll (system: pkgs: {
        default = pkgs.mkShell {
          packages = [
            wiz.packages.${system}.wiz   # wiz and grail
            pkgs.yosys                   # synthesis
            pkgs.nextpnr                 # place and route (nextpnr-ice40)
            pkgs.icestorm                # icepack, icetime, iceprog
            pkgs.iverilog                # simulation of the emitted Verilog
            pkgs.coreutils               # stty, for the serial port
            pkgs.socat                   # a pseudo-terminal pair, for the fake board
          ];
        };
      });
    };
}
