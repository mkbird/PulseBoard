#!/bin/zsh
set -euo pipefail

DIR="${0:A:h}"
APP="$DIR/dist/CliptoPulse.app"

if [[ ! -d "$APP" ]]; then
  echo "正在首次构建 CliptoPulse.app..."
  "$DIR/Scripts/build-app.sh"
fi

echo "正在启动 CliptoPulse（菜单栏常驻采集 + 网页控制台 http://127.0.0.1:8766）..."
open "$APP"
