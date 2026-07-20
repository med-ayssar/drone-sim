{
  description = "PX4 ROS2 development environment";


  inputs = {

    nixpkgs.url =
      "github:NixOS/nixpkgs/nixos-24.05";


    flake-utils.url =
      "github:numtide/flake-utils";


    nix-ros-overlay.url =
      "github:lopsided98/nix-ros-overlay";

  };


  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      nix-ros-overlay,
    }:


    flake-utils.lib.eachDefaultSystem

    (system:

    let

      pkgs =
        import nixpkgs {

          inherit system;

          overlays = [
            nix-ros-overlay.overlays.default
          ];

          config.allowUnfree = true;

        };


      ros2 =
        import ./ros2 {
          inherit pkgs;
        };


      micro-xrce-dds-agent =
        import ./micro-xrce-dds-agent {
          inherit pkgs;
        };


      px4-msgs =
        import ./px4-msgs {
          inherit pkgs;
        };


      px4-autopilot =
        import ./px4-autopilot {
          inherit pkgs;
        };


    in {


      packages = {

        micro-xrce-dds-agent =
          micro-xrce-dds-agent.package;


        px4-msgs =
          px4-msgs.package;


        px4 =
          px4-autopilot.package;


        default =
          pkgs.symlinkJoin {

            name = "px4-stack";

            paths = [

              micro-xrce-dds-agent.package

              px4-msgs.package

              px4-autopilot.package

            ];

          };

      };



      devShells.default =

        pkgs.mkShell {


          packages = [

            ros2.shell

            micro-xrce-dds-agent.package

            px4-msgs.package

            px4-autopilot.package


            pkgs.git
            pkgs.tmux

          ];



          shellHook = ''

            echo ""
            echo "PX4 ROS2 environment"
            echo ""


            export ROS_DOMAIN_ID=0


            alias start-agent="
              MicroXRCEAgent udp4 -p 8888
            "


            alias start-px4="
              px4
            "

          '';

        };

    });
}
