#!/bin/zsh
# 构建 Weft.app。用法：scripts/build-app.sh [--install] [--universal]
#   --install    装到 ~/Applications 并重启
#   --universal  同时编 Apple 芯片 + Intel，合成通用二进制（发布用）
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/repo.env
VERSION=$(cat VERSION)
INSTALL=0; UNIVERSAL=0
for a in "$@"; do case $a in --install) INSTALL=1;; --universal) UNIVERSAL=1;; esac; done
swift build -c release --product Weft 2>&1 | grep -v -E "PlatformPath|XCTest|xcrun" || true
BIN=.build/release/Weft
[[ -x $BIN ]] || { echo "构建失败"; exit 1; }
if [[ $UNIVERSAL == 1 ]]; then
  swift build -c release --product Weft --triple x86_64-apple-macosx14.0 --scratch-path .build/x86 2>&1 | grep -v -E "PlatformPath|XCTest|xcrun" || true
  [[ -x .build/x86/release/Weft ]] || { echo "Intel 版构建失败"; exit 1; }
  mkdir -p .build/universal
  lipo -create -output .build/universal/Weft $BIN .build/x86/release/Weft
  BIN=.build/universal/Weft
fi
APP=build/Weft.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN $APP/Contents/MacOS/Weft
cp assets/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Weft</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleAllowMixedLocalizations</key><true/>
  <key>CFBundleDisplayName</key><string>Weft</string>
  <key>CFBundleExecutable</key><string>Weft</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
PLIST
# 用本机自签名证书签名：签名身份固定，授权不会因为重新编译而失效
IDENTITY=$(security find-identity -p codesigning 2>/dev/null | awk -F'"' '/Weft Local Signing/{print $2; exit}')
if [[ -n "$IDENTITY" ]]; then
  codesign --force -s "Weft Local Signing" $APP
else
  echo "⚠️ 没找到「Weft Local Signing」证书，使用临时签名（每次构建后需重新授权）"
  codesign --force -s - $APP
fi
echo "✓ $APP"
if [[ $INSTALL == 1 ]]; then
  pkill -x Weft || true
  # 等旧进程把后台窗口放回原位、真正退出，再启动新的（否则 open 会激活正在退出的旧进程）
  for _ in $(seq 1 30); do pgrep -x Weft >/dev/null || break; sleep 0.2; done
  rm -rf ~/Applications/Weft.app && mkdir -p ~/Applications && cp -R $APP ~/Applications/
  open ~/Applications/Weft.app
  for _ in $(seq 1 20); do pgrep -x Weft >/dev/null && break; sleep 0.3; done
  pgrep -x Weft >/dev/null || open ~/Applications/Weft.app
  echo "✓ 已安装到 ~/Applications/Weft.app 并启动"
fi
