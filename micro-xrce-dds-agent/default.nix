{ pkgs }:


{

package =

pkgs.stdenv.mkDerivation {


  pname="micro-xrce-dds-agent";

  version="main";


  src=./Micro-XRCE-DDS-Agent;



  nativeBuildInputs=[

    pkgs.cmake

    pkgs.pkg-config

  ];



  buildInputs=[

    pkgs.asio

    pkgs.openssl

  ];



  buildPhase=''

    mkdir build

    cd build


    cmake .. \
      -DCMAKE_BUILD_TYPE=Release


    make -j$NIX_BUILD_CORES

  '';



  installPhase=''

    mkdir -p $out/bin


    cp MicroXRCEAgent \
       $out/bin/

  '';

};

}
