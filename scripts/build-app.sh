#!/bin/zsh
# 构建 Weft.app（ad-hoc 签名）。用法：scripts/build-app.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Weft 2>&1 | grep -v -E "PlatformPath|XCTest|xcrun" || true
BIN=.build/release/Weft
[[ -x $BIN ]] || { echo "构建失败"; exit 1; }
APP=build/Weft.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN $APP/Contents/MacOS/Weft
cp assets/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.weft.app</string>
  <key>CFBundleName</key><string>Weft</string>
  <key>CFBundleDisplayName</key><string>Weft</string>
  <key>CFBundleExecutable</key><string>Weft</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.6.7</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
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
if [[ "${1:-}" == "--install" ]]; then
  pkill -x Weft || true
  # 等旧进程把后台窗口放回原位、真正退出，再启动新的（否则 open 会激活正在退出的旧进程）
  for _ in $(seq 1 30); do pgrep -x Weft >/dev/null || break; sleep 0.2; done
  rm -rf ~/Applications/Weft.app && mkdir -p ~/Applications && cp -R $APP ~/Applications/
  open ~/Applications/Weft.app
  for _ in $(seq 1 20); do pgrep -x Weft >/dev/null && break; sleep 0.3; done
  pgrep -x Weft >/dev/null || open ~/Applications/Weft.app
  echo "✓ 已安装到 ~/Applications/Weft.app 并启动"
fi
