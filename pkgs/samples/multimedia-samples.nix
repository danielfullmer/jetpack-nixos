{ autoAddDriverRunpath
, autoPatchelfHook
, cairo
, cudaPackages
, dpkg
, fetchurl
, l4t-camera
, l4t-cuda
, l4t-multimedia
, l4t-pva
, l4t-video-codec-openrm ? null
, l4tAtLeast
, l4tMajorMinorPatchVersion
, lib
, libdrm
, libglvnd
, opencv
, pango
, python3
, vulkan-headers
, vulkan-loader
, xorg
}:
# https://docs.nvidia.com/jetson/l4t-multimedia/group__l4t__mm__test__group.html
let
  inherit (cudaPackages)
    backendStdenv
    cuda_nvcc
    cudatoolkit
    libnvjpeg
    tensorrt
    ;
  inherit (xorg) libX11;
in
backendStdenv.mkDerivation {
  __structuredAttrs = true;
  strictDeps = true;

  pname = "multimedia-samples";
  inherit (l4t-multimedia) version;

  src = l4t-multimedia.samples;

  nativeBuildInputs = [ autoAddDriverRunpath autoPatchelfHook cuda_nvcc dpkg python3 ];
  buildInputs = [
    cairo
    cudatoolkit
    l4t-camera
    l4t-cuda
    l4t-multimedia
    libdrm
    libglvnd
    libX11
    opencv
    pango
    tensorrt
    vulkan-headers
    vulkan-loader
  ] ++ lib.optionals (l4tAtLeast "38") [
    libnvjpeg
    l4t-video-codec-openrm
    l4t-pva
  ];

  # Usually provided by pkg-config, but the samples don't use it.
  env.NIX_CFLAGS_COMPILE = builtins.toString [
    "-I${lib.getDev libdrm}/include/libdrm"
    "-I${lib.getDev opencv}/include/opencv4"

    # Workaround a CPPFLAG normally set in samples/Rules.mk not working since
    # TOP_DIR doesn't have the include dir
    "-I${lib.getDev l4t-multimedia}/include/libjpeg-8b"
  ];

  postPatch = ''
    substituteInPlace samples/Rules.mk \
      --replace-fail /usr/local/cuda "${cudatoolkit}"

    substituteInPlace samples/08_video_dec_drm/Makefile \
      --replace-fail /usr/bin/python "${python3}/bin/python"
  '';

  installPhase = ''
    runHook preInstall

    install -Dm 755 -t $out/bin $(find samples -type f -perm 755)
    rm -f $out/bin/*.h

    cp -r data $out/

    # patchelf dlopen'd libraries so autoPatchelfHook can find them
    for exe in $out/bin/*; do
      patchelf \
        --add-needed libcairo.so.2 \
        --add-needed libgobject-2.0.so.0 \
        --add-needed libpango-1.0.so.0 \
        --add-needed libpangocairo-1.0.so.0 \
        ${lib.optionalString (l4tAtLeast "38") ''
          --add-needed libnvjpeg.so.13 \
          --add-needed libnvcuvid.so.1 \
          --add-needed libnvidia-encode.so.1 \
          --add-needed libnvpvaumd_core.so \
        ''} \
        "$exe"
    done
    unset -v exe

    runHook postInstall
  '';
}
