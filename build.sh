#!/bin/bash
# MONO 桌宠 macOS 版 — 一键构建脚本
# 产物：MONO.app（通用二进制，Apple 芯片 + Intel 均可运行）
#
# 用法：
#   ./build.sh          构建并生成 MONO.app
#   ./build.sh zip      构建后顺便打出可分发的 MONO-mac.zip
#
# 依赖：Xcode 命令行工具（xcode-select --install）

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MONO"
BUNDLE_ID="io.github.hotpeter.mono"
MIN_MACOS="12.0"

echo "==> 1/5 编译 arm64（Apple 芯片）"
swiftc -O -target "arm64-apple-macos${MIN_MACOS}" \
    Sources/main.swift Sources/SystemStats.swift Sources/L10n.swift \
    Sources/Bubble.swift Sources/ControlServer.swift \
    -o /tmp/mono_build_arm

echo "==> 2/5 编译 x86_64（Intel）"
swiftc -O -target "x86_64-apple-macos${MIN_MACOS}" \
    Sources/main.swift Sources/SystemStats.swift Sources/L10n.swift \
    Sources/Bubble.swift Sources/ControlServer.swift \
    -o /tmp/mono_build_x64

echo "==> 3/5 合并通用二进制"
lipo -create -output /tmp/mono_build_univ /tmp/mono_build_arm /tmp/mono_build_x64

echo "==> 4/5 组装 MONO.app"
rm -rf "${APP_NAME}.app"
mkdir -p "${APP_NAME}.app/Contents/MacOS" "${APP_NAME}.app/Contents/Resources"
cp Info.plist "${APP_NAME}.app/Contents/Info.plist"
cp /tmp/mono_build_univ "${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
ditto Resources "${APP_NAME}.app/Contents/Resources"

echo "==> 5/5 签名（本机 adhoc 签名）"
codesign --force --sign - "${APP_NAME}.app"
codesign --verify --deep --strict "${APP_NAME}.app"

rm -f /tmp/mono_build_arm /tmp/mono_build_x64 /tmp/mono_build_univ

echo
echo "构建完成：$(pwd)/${APP_NAME}.app"
echo "本地试用：open ${APP_NAME}.app"

if [[ "${1:-}" == "zip" ]]; then
    echo
    echo "==> 打分发布包 MONO-mac.zip"
    python3 - <<'PYEOF'
import os, zipfile
items = []
for dirpath, dirnames, filenames in os.walk('MONO.app'):
    dirnames.sort(); filenames.sort()
    items.append((dirpath + '/', None, 0o40755))
    for f in filenames:
        p = os.path.join(dirpath, f)
        items.append((p, p, 0o100755 if os.access(p, os.X_OK) else 0o100644))
# 双许可：GPL-3.0 要求随二进制分发许可证全文；美术是 CC BY-NC-SA 4.0，同样随包附上
items.append(('LICENSE.txt', 'LICENSE', 0o100644))
items.append(('LICENSE-ART.txt', 'LICENSE-ART', 0o100644))
with zipfile.ZipFile('MONO-mac.zip', 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for name, src, mode in items:
        zi = zipfile.ZipInfo(name)          # 不写时间戳：保证任何人构建结果一致
        zi.external_attr = mode << 16
        zi.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(zi, b'' if src is None else open(src, 'rb').read())
print('已生成 MONO-mac.zip')
PYEOF
fi
