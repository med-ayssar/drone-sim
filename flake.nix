{
  description = "PX4 ROS2 development environment";
  inputs = {
    nix-ros-overlay.url =
      "github:lopsided98/nix-ros-overlay/master";
    nixpkgs.follows =
      "nix-ros-overlay/nixpkgs";
  };
  outputs =
    { self, nix-ros-overlay, nixpkgs }:
    nix-ros-overlay.inputs.flake-utils.lib.eachDefaultSystem
    (system:
      let
        pkgs =
          import nixpkgs {
            inherit system;
            overlays = [
              nix-ros-overlay.overlays.default
              # Patch foonathan-memory-vendor globally so every consumer
              # (ros2 env, px4-msgs, ...) shares the fix.
              (final: prev: {
                rosPackages = prev.rosPackages // {
                  humble = prev.rosPackages.humble.overrideScope
                    (rosFinal: rosPrev: {
                      foonathan-memory-vendor =
                        rosPrev.foonathan-memory-vendor.overrideAttrs
                        (old: {
                          NIX_CFLAGS_COMPILE =
                            (old.NIX_CFLAGS_COMPILE or "")
                            + " -Wno-error=deprecated-literal-operator";
                        });
                    });
                };
              })
            ];
            config.allowUnfree = true;
          };

        ros2 =
          with pkgs.rosPackages.humble;
          buildEnv {
            underlay = true;
            paths = [
              ros-core
              ros-base
              rclcpp
              rclpy
              std-msgs
              geometry-msgs
              sensor-msgs
              nav-msgs
              tf2
              tf2-ros
              rmw-fastrtps-cpp
              rmw-fastrtps-dynamic-cpp
              rosidl-default-generators
              rosidl-typesupport-c
              rosidl-typesupport-cpp
              rclcpp-lifecycle
            ];
          };

        micro-xrce-dds-agent =
          import ./flakes/micro-xrce-dds-agent { inherit pkgs; };
        px4-msgs =
          import ./flakes/px4-msgs { inherit pkgs; };
      in {
        # PX4/Gazebo are NOT built by Nix (Gazebo is not packaged in nixpkgs).
        # PX4-Autopilot lives as a git submodule and is built on the host via
        # ./setup.sh (runs PX4's own OS-specific dependency installer).
        packages = {
          micro-xrce-dds-agent = micro-xrce-dds-agent.package;
          px4-msgs = px4-msgs.package;
          default =
            pkgs.symlinkJoin {
              name = "px4-ros2-stack";
              paths = [
                micro-xrce-dds-agent.package
                px4-msgs.package
              ];
            };
        };

        devShells.default =
          pkgs.mkShell {
            name = "PX4 ROS2 Humble development environment";
            # QGroundControl is only packaged for Linux in nixpkgs (no Darwin
            # build for 4.4.5). On macOS, install the official QGC .dmg instead.
            packages = [
              ros2
              micro-xrce-dds-agent.package
              px4-msgs.package
              pkgs.colcon
              pkgs.git
              pkgs.tmux
            ] ++ pkgs.lib.optional (!pkgs.stdenv.isDarwin) pkgs.qgroundcontrol;
            shellHook = ''
              echo ""
              echo "PX4 ROS2 Humble environment"
              echo "  start-agent -> MicroXRCEAgent udp4 -p 8888"
              ${pkgs.lib.optionalString (!pkgs.stdenv.isDarwin)
                ''echo "  start-qgc   -> QGroundControl (MAVLink auto-connect, UDP 14550)"''}
              echo "  PX4 setup   -> ./setup.sh   (installs host deps, builds via submodule)"
              echo "  PX4 build   -> cd services/PX4-Autopilot && make px4_sitl gz_x500"
              echo ""
              export ROS_DOMAIN_ID=0
              alias start-agent="MicroXRCEAgent udp4 -p 8888"
              ${pkgs.lib.optionalString (!pkgs.stdenv.isDarwin)
                ''alias start-qgc="QGroundControl"''}
            '';
          };
      });
  nixConfig = {
    extra-substituters = [
      "https://ros.cachix.org"
    ];
    extra-trusted-public-keys = [
      "ros.cachix.org-1:dSyZxI8geDCJrwgvCOHDoAfOm5sV1wCPjBkKL+38Rvo="
    ];
  };
}
