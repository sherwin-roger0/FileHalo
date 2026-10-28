# Third-party software in FileHalo

The portable build bundles FFmpeg 9.0.2 and WebP 1.6.0, along with their dynamic library dependencies. These tools are separate command-line programs launched by FileHalo.

FFmpeg is built with GPL support enabled (`libx264` and `libx265` are enabled). Its applicable GPL and LGPL texts are in `build/FileHalo.app/Contents/Resources/ThirdPartyLicenses/`. The corresponding source projects are available here:

- FFmpeg 9.0.2: https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
- x264: https://code.videolan.org/videolan/x264
- x265 4.3: https://github.com/Multicorewareinc/x265/releases/tag/4.3
- SVT-AV1 4.2.0: https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v4.2.0/SVT-AV1-v4.2.0.tar.bz2
- dav1d 1.5.4: https://code.videolan.org/videolan/dav1d/-/archive/1.5.4/dav1d-1.5.4.tar.bz2
- libvmaf 3.2.1: https://github.com/Netflix/vmaf/archive/refs/tags/v3.2.1.tar.gz
- libvpx 1.17.0: https://github.com/webmproject/libvpx/archive/refs/tags/v1.17.0.tar.gz
- LAME 4.0: https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz
- Opus 1.6.1: https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.6.1.tar.gz
- OpenSSL 3.5.9: https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz
- xz 5.8.4: https://github.com/tukaani-project/xz/releases/download/v5.8.4/xz-5.8.4.tar.gz
- libpng 1.6.59: https://downloads.sourceforge.net/project/libpng/libpng16/1.6.59/libpng-1.6.59.tar.xz
- libjpeg-turbo 3.2.0: https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz
- WebP 1.6.0: https://chromium.googlesource.com/webm/libwebp/+/refs/tags/v1.6.0/

The FFmpeg binary reports its complete configure options with `ffmpeg -version`; those options are recorded in `build/FFMPEG-BUILD.txt`. Other bundled libraries and their copyright notices are listed in `build/FileHalo.app/Contents/Resources/ThirdPartyLicenses/DEPENDENCIES.txt`.

This project is distributed free of charge. The bundled FFmpeg remains under its stated open-source licenses; this notice does not replace those license terms.
