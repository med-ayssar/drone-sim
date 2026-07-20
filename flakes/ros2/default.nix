{ pkgs }:

{

  shell =

    pkgs.mkShell {


      packages = with pkgs; [

        rosPackages.humble.ros-core

        rosPackages.humble.ros2cli

        rosPackages.humble.rmw-fastrtps-cpp


        colcon

        python3

      ];


      shellHook = ''

        source ${pkgs.rosPackages.humble.ros-core}/setup.bash

      '';

    };

}
