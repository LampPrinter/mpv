#!/usr/bin/env zsh


trash ~"/.config/mpv/[extras]/build mpv/mpv/build"

set -ex

meson setup build
meson compile -C build
# test the binary we just built
./build/mpv --version

./TOOLS/osxbundle.py --skip-deps build/mpv
if [[ $1 == "--static" ]]; then
	dylibbundler --bundle-deps --dest-dir build/mpv.app/Contents/MacOS/lib/ --install-path @executable_path/lib/ --fix-file build/mpv.app/Contents/MacOS/mpv
	# test the app binary to make sure all the dylibs made it okay
	./build/mpv.app/Contents/MacOS/mpv --version
fi