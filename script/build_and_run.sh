#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="PhotoolsApp"
BUNDLE_ID="com.vincentchyu.photools.macos"
MIN_SYSTEM_VERSION="13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PACKAGE="$ROOT_DIR/apps/macos/PhotoolsApp"
if [[ ! -d "$APP_PACKAGE" && -d "$ROOT_DIR/app/macos/PhotoolsApp" ]]; then
  APP_PACKAGE="$ROOT_DIR/app/macos/PhotoolsApp"
fi
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
PHOTOOLS_BINARY="$DIST_DIR/photools"
PHOTOOLS_DYLIB="$DIST_DIR/libphotools.dylib"

# 自动探测有效 Go 编译器 (优先 asdf 活跃版本)
GO_CMD=""
if command -v go >/dev/null 2>&1; then
  GO_CMD="go"
elif [[ -n "$HOME" && -x "$HOME/.asdf/installs/golang/1.27.1/go/bin/go" ]]; then
  GO_CMD="$HOME/.asdf/installs/golang/1.27.1/go/bin/go"
elif [[ -x "$HOME/.asdf/shims/go" ]]; then
  GO_CMD="$HOME/.asdf/shims/go"
elif [[ -x "/usr/local/go/bin/go" ]]; then
  GO_CMD="/usr/local/go/bin/go"
else
  echo "❌ 错误: 未找到有效 Go 编译器，请检查 asdf 或 PATH" >&2
  exit 1
fi

if [[ "$MODE" == "clean" || "$MODE" == "--clean" ]]; then
  echo "🧹 清理构建产物与 Swift 缓存..."
  rm -rf "$DIST_DIR" "$APP_PACKAGE/.build"
  echo "✨ 清理完成"
  exit 0
fi

# 仅杀死已运行的 App 实例，绝不使用 pkill -f 以免误伤当前执行脚本
killall "$APP_NAME" >/dev/null 2>&1 || pkill -x "$APP_NAME" >/dev/null 2>&1 || true

mkdir -p "$DIST_DIR"

echo "📦 [1/4] 编译 Go C-Shared 进程内动态库 (libphotools.dylib)..."
"$GO_CMD" build -buildmode=c-shared -o "$PHOTOOLS_DYLIB" ./cmd/photools-cshared

echo "📦 [2/4] 编译 Go 独立 CLI 工具 (photools)..."
"$GO_CMD" build -o "$PHOTOOLS_BINARY" ./cmd/photools

echo "📦 [3/4] 编译 Swift 原生 macOS App..."
swift build --package-path "$APP_PACKAGE"
SWIFT_BIN_DIR="$(swift build --package-path "$APP_PACKAGE" --show-bin-path)"
BUILD_BINARY="$SWIFT_BIN_DIR/$APP_NAME"

echo "📦 [4/4] 组装自包含 App Bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_FRAMEWORKS" "$APP_RESOURCES"

cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

cp "$PHOTOOLS_DYLIB" "$APP_FRAMEWORKS/"
cp "$PHOTOOLS_BINARY" "$APP_MACOS/"

# 打包全套技术设计与使用指南文档 (docs/*.md)
if [[ -d "$ROOT_DIR/docs" ]]; then
  cp -r "$ROOT_DIR/docs" "$APP_RESOURCES/"
fi
cp "$ROOT_DIR/README.md" "$APP_RESOURCES/" 2>/dev/null || true

# 打包离线地理数据包 (geodata)
if [[ -d "$ROOT_DIR/geodata" ]]; then
  cp -r "$ROOT_DIR/geodata" "$APP_RESOURCES/"
fi

# 打包 MapLibre 3D 地形离线前端库 (0秒即开免下载)
if [[ -d "$APP_PACKAGE/Resources/maplibre" ]]; then
  cp -r "$APP_PACKAGE/Resources/maplibre" "$APP_RESOURCES/"
fi

# 打包高清原生应用图标 (AppIcon.icns)
if [[ -f "$ROOT_DIR/img/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/img/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
elif [[ -f "$APP_PACKAGE/Resources/AppIcon.icns" ]]; then
  cp "$APP_PACKAGE/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
fi

# 自动探测并内置 ExifTool 运行时 (实现免安装自包含)
SYS_EXIFTOOL="$(which exiftool 2>/dev/null || true)"
if [[ -n "$SYS_EXIFTOOL" && -x "$SYS_EXIFTOOL" ]]; then
  EXIFTOOL_DIR="$(dirname "$SYS_EXIFTOOL")"
  mkdir -p "$APP_RESOURCES/vendor/exiftool"
  cp "$SYS_EXIFTOOL" "$APP_RESOURCES/vendor/exiftool/exiftool"
  chmod +x "$APP_RESOURCES/vendor/exiftool/exiftool"
  # 如果存在 lib/perl 模块目录则一并打包
  if [[ -d "$EXIFTOOL_DIR/lib" ]]; then
    cp -r "$EXIFTOOL_DIR/lib" "$APP_RESOURCES/vendor/exiftool/"
  fi
fi

# 配置 rpath 动态链接
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY" 2>/dev/null || true

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "🔏 执行本地 Ad-hoc 代码签名与安全封包..."
codesign --force --sign - "$APP_FRAMEWORKS/libphotools.dylib" 2>/dev/null || true
codesign --force --sign - "$APP_BINARY" 2>/dev/null || true
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

echo "🎉 photools 自包含 App Bundle 组装并签名完成: $APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --verify|verify|--build-only)
    echo "✅ 构建验证完成，跳过自动启动"
    ;;
  --dmg|dmg|--package)
    PRIMARY_DMG="$DIST_DIR/photools-macOS.dmg"
    ALIAS_DMG="$DIST_DIR/${APP_NAME}.dmg"
    DMG_TMP_DIR="$DIST_DIR/dmg_tmp"
    echo "💿 [5/5] 开始生成标准 macOS 磁盘安装镜像 (DMG)..."
    rm -rf "$DMG_TMP_DIR" "$PRIMARY_DMG" "$ALIAS_DMG"
    mkdir -p "$DMG_TMP_DIR"
    cp -r "$APP_BUNDLE" "$DMG_TMP_DIR/"
    ln -s /Applications "$DMG_TMP_DIR/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_TMP_DIR" -ov -format UDZO "$PRIMARY_DMG" >/dev/null
    rm -rf "$DMG_TMP_DIR"
    cp "$PRIMARY_DMG" "$ALIAS_DMG"
    shasum -a 256 "$PRIMARY_DMG" > "${PRIMARY_DMG}.sha256"
    shasum -a 256 "$ALIAS_DMG" > "${ALIAS_DMG}.sha256"
    echo "🎉 macOS 发布级 DMG 镜像封包成功: $PRIMARY_DMG"
    echo "🔗 镜像别名已同步: $ALIAS_DMG"
    echo "🔑 SHA256 校验和已生成: ${PRIMARY_DMG}.sha256"
    ;;
  *)
    echo "用法: $0 [run|--build-only|--debug|--verify|--dmg|clean]"
    ;;
esac
