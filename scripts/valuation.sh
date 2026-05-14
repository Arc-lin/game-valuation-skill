#!/bin/bash
set -euo pipefail

# ─── 配置 ──────────────────────────────────────────────────
BASE_URL="https://gamemarket.yy.com"
QRCodeDir="${GAME_VALUATION_QRCODE_DIR:-/tmp/game-valuation-qrcode}"
COOKIE="yyuid=2988686730; udb_oar=3C1383D87E14AA391A89D29DEAEA67AE8679E7D10E0B00A870D3CC3C683C49DC9C01BF6990BE1F884E84C00B40380B287B8776E12BA29738145655163FF3F3210A1462229DACB98C2F37E17DFDA257C755604973970831DDDFFC4C21AFD6ED6A9AD0B67ECE48F0815F86A0F4C71215F87E4F62455D24EB25ACB18233A472B2FA8DF70E9ED0F664C3D1CE075715A0F8EEBEF01E690AFEE66CD6B4C94BABA0A4AFBB1206F75586CA2A1792D951B533E27B5B89ECD20EE7690D765EDB4FA08BC6EE16C51D009379B5078B71A5608D3C363DAD3CC7D622A1BA30633E63E8280449496B70750AA1ADD1230CBA5FEBECBC6C7D8C1F958FDFAD413BE34B68BDA64FD2B28770376A6BEDC016BBF4789377DA1F10FBC847C4B66BAC640207933C385A0B699EA966D48467385725FE8C0B0B93A86FC030CE017232FD148DDD6DF3CF647C92"

# ─── 工具函数 ──────────────────────────────────────────────
md5hex() {
  printf '%s' "$1" | python3 -c 'import sys,hashlib;print(hashlib.md5(sys.stdin.buffer.read()).hexdigest())'
}

now_ms() {
  python3 -c 'import time;print(int(time.time()*1000))'
}

gen_uuid() {
  python3 -c 'import uuid;print(uuid.uuid4())'
}

datetime_compact() {
  python3 -c 'import datetime;print(datetime.datetime.now().strftime("%Y%m%d%H%M%S"))'
}

open_file() {
  case "$(uname -s)" in
    Darwin) open "$1" ;;
    Linux) xdg-open "$1" 2>/dev/null ;;
  esac
}

# ─── HTTP 请求 ─────────────────────────────────────────────
do_request() {
  local method="$1" path="$2" body="${3:-}"

  local nonce timestamp sig traceid
  nonce=$(gen_uuid)
  timestamp=$(now_ms)
  sig=$(md5hex "market_app${nonce}${timestamp}")
  traceid="$(md5hex "${nonce}")-$(datetime_compact)"

  local url="${BASE_URL}${path}"
  local args=(
    -s -X "$method"
    -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36"
    -H "X-Appid: market_app"
    -H "X-Nonce: ${nonce}"
    -H "X-Signature: ${sig}"
    -H "X-Timestamp: ${timestamp}"
    -H "Origin: https://mall.yy.com"
    -H "Referer: https://mall.yy.com/"
    -H "Cookie: ${COOKIE}"
  )

  if [ -n "$body" ]; then
    args+=(-H "Content-Type: application/json" -d "$body")
  fi

  curl "${args[@]}" "$url"
}

do_get()  { do_request GET "$1"; }
do_post() { do_request POST "$1" "$2"; }

# ─── 命令实现 ──────────────────────────────────────────────
cmd_games() { do_get "/category/queryAccountLiteList?support=4"; }
cmd_attrs() { do_get "/attribute/queryAttrsEcho4Ai?gid=$1"; }

cmd_commit() {
  local gameid="$1" attr_items="$2"
  local body
  body=$(printf '{"categoryId":"%s","attrItems":%s,"hdid":""}' "$gameid" "$attr_items")
  do_post "/valuation/commit" "$body"
}

cmd_execute() {
  local body
  body=$(printf '{"recordId":%s,"hdid":""}' "$1")
  do_post "/valuation/execute" "$body"
}

cmd_detail() { do_get "/valuation/detail?recordId=$1&hdid="; }

cmd_report() {
  cmd_detail "$1" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    resp = json.loads(raw)
except:
    print(raw)
    sys.exit(0)

if resp.get("code") != 0:
    print(raw)
    sys.exit(0)

d = resp["data"]
av = d.get("accountValue", {})

if av.get("predictValuation", 0) == 0 and not av.get("surpassedUser"):
    print("估值结果暂未生成，请稍后再试。如果问题持续，建议重新提交估值。")
    sys.exit(0)

gn = d["gameName"]
pv = av["predictValuation"]
mn = av["minValuation"]
mx = av["maxValuation"]
su = av["surpassedUser"]
mi = av["mostValueItem"]

lines = []
lines.append("\U0001f3ae " + gn + " \u2014 \u8d26\u53f7\u4f30\u503c\u62a5\u544a")
lines.append("\u2501" * 35)
lines.append("\U0001f4b0 \u9884\u4f30\u4ef7\u683c: \u00a5" + str(pv))
lines.append("\U0001f4c8 \u4ef7\u683c\u533a\u95f4: \u00a5" + str(mn) + " ~ \u00a5" + str(mx))
lines.append("\U0001f3c6 \u8d85\u8d8a\u7528\u6237: " + su)
lines.append("\U0001f451 \u6700\u503c\u94b1\u5355\u54c1: " + mi)
lines.append("")
lines.append("\U0001f4ca \u6838\u5fc3\u6570\u636e:")
for item in d.get("coreData", []):
    lines.append("  " + item["featureLabel"] + ": " + str(item["featureValue"]) + "/" + str(item["maxNum"]))
lines.append("")
lines.append("\U0001f50d \u8be6\u7ec6\u4f30\u503c: https://mall.yy.com/?pageId=20000")
print("\n".join(lines))
'
}

save_and_open_qr() {
  local auth_code="$1" auth_type="$2" record_id="$3"
  local qr_path="${QRCodeDir}/qrcode_${record_id}.png"

  mkdir -p "$QRCodeDir"

  if [ "$auth_type" = "1" ]; then
    if echo "$auth_code" | python3 -c 'import base64,sys;sys.stdout.buffer.write(base64.b64decode(sys.stdin.read().strip()))' > "$qr_path" 2>/dev/null; then
      open_file "$qr_path"
    else
      local txt_path="${QRCodeDir}/qrcode_${record_id}_datauri.txt"
      echo "data:image/png;base64,${auth_code}" > "$txt_path"
      open_file "$txt_path"
      qr_path="$txt_path"
    fi
  elif [ "$auth_type" = "2" ]; then
    curl -s -o "$qr_path" "$auth_code"
    local url_path="${QRCodeDir}/qrcode_${record_id}_url.txt"
    echo "$auth_code" > "$url_path"
    open_file "$qr_path"
  fi

  echo "$qr_path"
}

cmd_scan() {
  local auth_code="$1" auth_type="$2" record_id="$3" scan_uuid="$4" uuid_create_time="$5"

  # 1. 保存并打开二维码
  local qr_path
  qr_path=$(save_and_open_qr "$auth_code" "$auth_type" "$record_id")

  # 2. 轮询扫码结果
  local poll_path="/valuation/queryAssetVerifyAuthResult?uuid=${scan_uuid}&recordId=${record_id}&uuidCreateTime=${uuid_create_time}&hdid="
  local scan_ok=false

  for _ in $(seq 1 120); do
    local biz_code
    biz_code=$(do_get "$poll_path" | python3 -c '
import json, sys
try:
    print(json.loads(sys.stdin.read())["data"]["bizCode"])
except:
    print(-1)
')
    if [ "$biz_code" = "0" ]; then
      scan_ok=true
      break
    fi
    sleep 5
  done

  # 3. 清理二维码
  rm -f "$qr_path" 2>/dev/null

  if [ "$scan_ok" = false ]; then
    echo "Error: 二维码已过期，请重新提交估值" >&2
    exit 1
  fi

  # 4. 执行估值
  cmd_execute "$record_id"
}

# ─── 主入口 ────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Usage: valuation.sh <command> [args...]

Commands:
  games                              查询支持的游戏列表
  attrs <gameId>                     获取游戏属性配置
  commit <gameId> '<attrItems_json>' 提交估值
  scan <authCode> <authType> <recordId> <uuid> <uuidCreateTime>  扫码验证（保存二维码+轮询+执行估值）
  execute <recordId>                 执行估值（authType=0 时直接调用）
  detail <recordId>                  获取估值报告（JSON）
  report <recordId>                  获取估值报告（格式化）
EOF
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

case "$1" in
  games) cmd_games ;;
  attrs)
    [ $# -lt 2 ] && echo "Usage: valuation.sh attrs <gameId>" && exit 1
    cmd_attrs "$2"
    ;;
  commit)
    [ $# -lt 3 ] && echo "Usage: valuation.sh commit <gameId> '<attrItems_json>'" && exit 1
    cmd_commit "$2" "$3"
    ;;
  execute)
    [ $# -lt 2 ] && echo "Usage: valuation.sh execute <recordId>" && exit 1
    cmd_execute "$2"
    ;;
  detail)
    [ $# -lt 2 ] && echo "Usage: valuation.sh detail <recordId>" && exit 1
    cmd_detail "$2"
    ;;
  report)
    [ $# -lt 2 ] && echo "Usage: valuation.sh report <recordId>" && exit 1
    cmd_report "$2"
    ;;
  scan)
    [ $# -lt 6 ] && echo "Usage: valuation.sh scan <authCode> <authType> <recordId> <uuid> <uuidCreateTime>" && exit 1
    cmd_scan "$2" "$3" "$4" "$5" "$6"
    ;;
  *) usage; exit 1 ;;
esac
