{ pkgs }:

let
  inherit (pkgs) lib stdenv;

  # The superbuild git-clones its deps at build time. On a network behind a
  # TLS-inspection proxy (e.g. corporate Zscaler), github.com is served with a
  # certificate re-signed by the proxy's root CA, which is NOT in the standard
  # public bundle -- clones then fail with "unable to get local issuer
  # certificate". Off such a network (a private PC) nothing extra is needed.
  #
  # So the extra CA is OPT-IN: point MICRO_XRCE_EXTRA_CACERT at the proxy root CA
  # (an absolute path) and build impurely. On a private PC just build normally.
  #   corporate: MICRO_XRCE_EXTRA_CACERT=/etc/ssl/certs/zscaler.pem \
  #                nix build --impure .#micro-xrce-dds-agent
  #   private:   nix build .#micro-xrce-dds-agent
  extraCaEnv = builtins.getEnv "MICRO_XRCE_EXTRA_CACERT";
  caBundle =
    if extraCaEnv != ""
    then pkgs.cacert.override { extraCertificateFiles = [ (/. + extraCaEnv) ]; }
    else pkgs.cacert;
  caFile = "${caBundle}/etc/ssl/certs/ca-bundle.crt";
in
{

  package = stdenv.mkDerivation {

    pname = "micro-xrce-dds-agent";

    version = "2.4.3";


    src = pkgs.fetchgit {
      url = "https://github.com/eProsima/Micro-XRCE-DDS-Agent.git";
      rev = "v2.4.3";
      # hash = "sha256-nBJ+WuoZhB3+/NiYAH/l1r0BK1aFzAUfGpyOKpWC1sg=";
      hash = "sha256-t2PZurWc8Kbkm3zFyNwHQea4Yj+zHWFXFqZ0E19km54=";
    };


    nativeBuildInputs = [
      pkgs.cmake
      pkgs.pkg-config
      pkgs.git
      caBundle
    ]
    # Linux: rewrite ELF RPATHs so the binary finds the bundled .so files.
    ++ lib.optionals stdenv.isLinux [ pkgs.autoPatchelfHook ]
    # macOS: rewrite Mach-O install names so the binary finds the bundled .dylib.
    ++ lib.optionals stdenv.isDarwin [ pkgs.fixDarwinDylibNames ];


    buildInputs = [
      pkgs.asio
      pkgs.openssl
      pkgs.tinyxml-2
    ];

    SSL_CERT_FILE = caFile;
    # The libcurl backing this nixpkgs git honours CURL_CA_BUNDLE. (Note: do NOT
    # set GIT_SSL_CAINFO / http.sslCAInfo -- with this libcurl it overrides and
    # breaks verification instead of helping.)
    CURL_CA_BUNDLE = caFile;
    NIX_CFLAGS_COMPILE = "-Wno-error=deprecated-literal-operator";

    cmakeFlags = [
      # Superbuild: let the Agent's CMake fetch + build its own dependency
      # versions (fastcdr, fastdds, foonathan_memory, spdlog) into temp_install.
      "-DUAGENT_SUPERBUILD=ON"
      "-DUAGENT_BUILD_EXECUTABLE=ON"
    ] ++ lib.optionals stdenv.isDarwin [
      # SocketCAN is Linux-only.
      "-DUAGENT_SOCKETCAN_PROFILE=OFF"
    ];

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin $out/lib

      # The superbuild disables the final install step (INSTALL_COMMAND "" in
      # cmake/SuperBuild.cmake), so the Agent's own artifacts are left in the
      # build tree while its dependencies are fully installed under
      # temp_install. Assemble a complete, consumable prefix by hand.
      #
      # find (no shell globs) keeps this safe when a pattern matches nothing,
      # and the .so / .dylib split covers Linux and macOS.

      # 1. The MicroXRCEAgent executable.
      find . -type f -name MicroXRCEAgent -perm -u+x \
        -exec install -Dm755 {} $out/bin/MicroXRCEAgent \;

      # 2. The Agent library + any superbuild dependency shared libraries that
      #    were built shared (fastcdr, fastdds, ...). Include symlinks (-type l)
      #    so the SONAME links (e.g. libmicroxrcedds_agent.so.2.4 -> ....2.4.3)
      #    come along -- the executable is linked against the SONAME, not the
      #    fully-versioned file.
      find . \( -type f -o -type l \) \
        \( -name '*.so' -o -name '*.so.*' -o -name '*.dylib' \) \
        -not -path '*/CMakeFiles/*' \
        -exec cp -a {} $out/lib/ \;

      # 3. The dependency install trees (headers, CMake config, static libs,
      #    tools) so downstream consumers can find_package() them later.
      if [ -d temp_install ]; then
        for dep in temp_install/*/; do
          [ -d "$dep" ] && cp -a "$dep". "$out"/
        done
      fi

      # Some deps install into lib64; fold it into lib ourselves so the
      # moveLib64 fixup hook doesn't choke on a leftover non-empty lib64.
      if [ -d $out/lib64 ]; then
        cp -a $out/lib64/. $out/lib/
        rm -rf $out/lib64
      fi

      # The in-tree artifacts were linked with RPATHs into the build directory,
      # which the tmpdir audit rejects. Strip them on Linux; autoPatchelfHook
      # then re-derives correct RPATHs into $out/lib (+ buildInputs). Non-ELF
      # files hit by the find just make patchelf no-op with an ignored error.
      ${lib.optionalString stdenv.isLinux ''
        find $out -type f \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) \
          -exec patchelf --remove-rpath {} \; 2>/dev/null || true
      ''}

      runHook postInstall
    '';

  };

}
