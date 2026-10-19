#!/bin/zsh
# Build "iPod Drop.app" with its own Python engine inside (no dependency on this checkout).
# Usage: tools/build_app.sh [--install] [--dmg]
#   --install  copy the app to /Applications
#   --dmg      also package build/iPod-Drop.dmg (drag-to-Applications disk image)
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"
BUILD="$ROOT/build"
APP="$BUILD/Release/iPod Drop.app"
VENV_SITE="$ROOT/.venv/lib/python3.12/site-packages"
# The .venv's interpreter is a relocatable python-build-standalone install managed by uv.
PY_HOME="$(cd "$(dirname "$(readlink -f "$ROOT/.venv/bin/python")")/.." && pwd)"

echo "› Building app"
xcodegen generate --quiet
xcodebuild -project iPodDrop.xcodeproj -scheme iPodDrop -configuration Release \
  -derivedDataPath "$BUILD/DerivedData" -destination "platform=macOS,arch=arm64" build -quiet
rm -rf "$APP"
mkdir -p "$BUILD/Release"
cp -R "$BUILD/DerivedData/Build/Products/Release/iPod Drop.app" "$APP"

ENGINE="$APP/Contents/Resources/engine"
PY="$ENGINE/python"
SITE="$PY/lib/python3.12/site-packages"

echo "› Copying Python $(basename "$PY_HOME")"
mkdir -p "$ENGINE"
rsync -a --delete \
  --exclude 'lib/python3.12/test/' --exclude 'lib/python3.12/idlelib/' \
  --exclude 'lib/python3.12/tkinter/' --exclude 'lib/python3.12/turtledemo/' \
  --exclude 'lib/python3.12/ensurepip/' --exclude 'lib/python3.12/site-packages/' \
  --exclude 'lib/tcl*' --exclude 'lib/tk*' --exclude 'lib/itcl*' --exclude 'lib/thread*' \
  --exclude 'include/' --exclude 'share/' --exclude '__pycache__/' \
  "$PY_HOME/" "$PY/"
rm -f "$PY/lib/python3.12/EXTERNALLY-MANAGED"

echo "› Copying engine dependencies (only what the engine loads)"
# Qt: the engine uses Core, Gui, Widgets, Network, Multimedia (+ DBus as a dependency).
QT_KEEP='QtCore|QtGui|QtWidgets|QtNetwork|QtMultimedia|QtDBus'
mkdir -p "$SITE"
rsync -a --delete \
  --exclude '__pycache__/' --exclude '*.pyi' \
  --exclude 'pip*' --exclude '_virtualenv*' --exclude 'distutils-precedence.pth' \
  --exclude 'objc/' --exclude 'PyObjC*' --exclude 'pyobjc*' --exclude 'AppKit/' \
  --exclude 'Foundation/' --exclude 'CoreFoundation/' --exclude 'PyObjCTools/' \
  --exclude 'scipy*' --exclude 'sklearn*' --exclude 'scikit_learn*' \
  --exclude 'numba*' --exclude 'llvmlite*' \
  --exclude 'PySide6/Qt/qml/' --exclude 'PySide6/Qt/translations/' \
  --exclude 'PySide6/Qt/metatypes/' --exclude 'PySide6/Qt/libexec/' \
  --exclude 'PySide6/include/' --exclude 'PySide6/typesystems/' --exclude 'PySide6/glue/' \
  --exclude 'PySide6/scripts/' --exclude 'PySide6/examples/' \
  --exclude 'PySide6/Designer.app/' --exclude 'PySide6/Assistant.app/' --exclude 'PySide6/Linguist.app/' \
  "$VENV_SITE/" "$SITE/"

# Drop Qt frameworks and bindings the engine never loads.
for fw in "$SITE"/PySide6/Qt/lib/*.framework(N); do
  name=${fw:t:r}
  [[ $name =~ "^($QT_KEEP)$" ]] || rm -rf "$fw"
done
for mod in "$SITE"/PySide6/Qt*.abi3.so(N); do
  name=${mod:t:r:r}
  [[ $name =~ "^($QT_KEEP)$" ]] || rm -f "$mod"
done
for plugins in "$SITE"/PySide6/Qt/plugins/*(N/); do
  case ${plugins:t} in
    platforms|multimedia|imageformats|tls|networkinformation) ;;
    *) rm -rf "$plugins" ;;
  esac
done

echo "› Copying the engine package"
mkdir -p "$ENGINE/app"
rsync -a --delete --exclude '__pycache__/' "$ROOT/ipod_engine" "$ENGINE/app/"

echo "› Precompiling bytecode"
"$PY/bin/python3" -m compileall -q -j 0 "$PY/lib/python3.12" "$ENGINE/app" >/dev/null || true

echo "› Smoke test: the bundled engine starts and imports iOpenPod"
QT_QPA_PLATFORM=offscreen PYTHONPATH="$ENGINE/app" "$PY/bin/python3" -c \
  "import ipod_engine.core, iOpenPod.app.context; print('engine imports ok')"

echo "› Signing (ad-hoc)"
find "$ENGINE" -type f \( -name '*.so' -o -name '*.dylib' \) -print0 \
  | xargs -0 -n 64 -P 8 codesign --force --sign - --timestamp=none 2>/dev/null
find "$ENGINE" -type d -name '*.framework' -prune -print0 \
  | xargs -0 -n 16 codesign --force --sign - --timestamp=none 2>/dev/null
codesign --force --sign - --timestamp=none "$PY/bin/python3.12"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify "$APP" && echo "signature ok"

echo "› $(du -sh "$APP" | cut -f1)  $APP"

if [[ " $* " == *" --dmg "* ]]; then
  echo "› Packaging DMG"
  STAGE="$BUILD/dmg"
  rm -rf "$STAGE" "$BUILD/iPod-Drop.dmg"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "iPod Drop" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov \
    "$BUILD/iPod-Drop.dmg" >/dev/null
  rm -rf "$STAGE"
  echo "› $(du -sh "$BUILD/iPod-Drop.dmg" | cut -f1)  $BUILD/iPod-Drop.dmg"
fi

if [[ " $* " == *" --install "* ]]; then
  osascript -e 'tell application "iPod Drop" to quit' 2>/dev/null || true
  rm -rf "/Applications/iPod Drop.app"
  cp -R "$APP" /Applications/
  echo "› Installed to /Applications/iPod Drop.app"
fi
