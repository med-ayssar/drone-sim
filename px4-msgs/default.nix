{ pkgs }:


{

package =

pkgs.stdenv.mkDerivation {


pname="px4-msgs";

version="main";


src=./px4_msgs;



nativeBuildInputs=[

 pkgs.colcon

 pkgs.cmake

 pkgs.python3

];



buildPhase=''

source ${pkgs.rosPackages.humble.ros-core}/setup.bash


colcon build \
 --symlink-install

'';



installPhase=''

mkdir -p $out


cp -r install $out/

'';


};

}
