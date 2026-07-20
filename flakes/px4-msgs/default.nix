{ pkgs }:

let
  ros = pkgs.rosPackages.humble;
in
{
  package = ros.buildRosPackage {
    pname = "px4-msgs";
    version = "main";

    src = pkgs.fetchgit {
      url = "https://github.com/PX4/px4_msgs.git";
      rev = "refs/heads/main";
      hash = "sha256-H66Ae0iZeQ+qjruLPSzS3JW5dt+U7KgVhv6YxdnlmbA=";
    };

    buildType = "ament_cmake";

    # buildtool_depend in package.xml
    nativeBuildInputs = [
      ros.ament-cmake
      ros.ament-cmake-core
      ros.rosidl-default-generators
    ];

    propagatedBuildInputs = [
      ros.builtin-interfaces
      ros.geometry-msgs
      ros.sensor-msgs
      ros.std-msgs
      ros.rosidl-default-runtime
    ];

    meta = {
      description = "PX4 ROS 2 message definitions (px4_msgs)";
      homepage = "https://github.com/PX4/px4_msgs";
    };
  };
}
