{ pkgs }:


{

package =

pkgs.stdenv.mkDerivation {


pname="px4";

version="main";


src=./PX4-Autopilot;



nativeBuildInputs=[

 pkgs.gcc

 pkgs.gnumake

 pkgs.cmake

 pkgs.ninja

 pkgs.python3


 pkgs.python3Packages.jinja2

 pkgs.python3Packages.pyserial

 pkgs.python3Packages.numpy

 pkgs.python3Packages.packaging

];



buildPhase=''

make px4_sitl_default

'';



installPhase=''

mkdir -p $out/bin


cp build/px4_sitl_default/bin/px4 \
$out/bin/

'';


};

}
