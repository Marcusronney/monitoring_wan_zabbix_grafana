bash
#!/usr/bin/env bash
# speedtest_zabbix.sh - roda o Speedtest CLI (Ookla) e envia o resultado ao Zabbix
#
# Uso:
#   speedtest_zabbix.sh -s <host no Zabbix> -z <servidor Zabbix> [-i <interface> | -a <IP de origem>]
#                       [-e <regex do provedor esperado>] [-S <id do servidor speedtest>]
set -u

ZBX_SERVER=""
ZBX_HOST=""
IFACE=""
SRC_IP=""
EXPECT_ISP=""
SERVER_ID=""
KEY="speedtestX"
LOG_TAG="speedtest_zabbix"

usage() { sed -n '2,6p' "$0"; exit 2; }
while getopts "s:z:i:a:e:S:h" o; do
  case "$o" in
    s) ZBX_HOST="$OPTARG" ;;
    z) ZBX_SERVER="$OPTARG" ;;
    i) IFACE="$OPTARG" ;;
    a) SRC_IP="$OPTARG" ;;
    e) EXPECT_ISP="$OPTARG" ;;
    S) SERVER_ID="$OPTARG" ;;
    *) usage ;;
  esac
done
[ -n "$ZBX_HOST" ] && [ -n "$ZBX_SERVER" ] || usage

log() { logger -t "$LOG_TAG" "[$ZBX_HOST] $*"; echo "[$ZBX_HOST] $*" >&2; }

for bin in speedtest jq zabbix_sender; do
  command -v "$bin" >/dev/null 2>&1 || { log "ERRO: '$bin' nao encontrado"; exit 1; }
done

# Evita duas execucoes ao mesmo tempo para o mesmo host
exec 9>"/tmp/${LOG_TAG}_${ZBX_HOST}.lock"
flock -n 9 || { log "ja existe uma execucao em andamento"; exit 0; }

args=(--accept-license --accept-gdpr -f json)
[ -n "$IFACE" ]     && args+=(--interface="$IFACE")
[ -n "$SRC_IP" ]    && args+=(--ip="$SRC_IP")
[ -n "$SERVER_ID" ] && args+=(--server-id="$SERVER_ID")

OUT="$(timeout 180 speedtest "${args[@]}" 2>/dev/null)"
RC=$?

# Nao envia nada se o teste falhou: valor vazio gera erro de pre-processamento no Zabbix
if [ $RC -ne 0 ] || ! JSON="$(printf '%s' "$OUT" | jq -ce 'select(.type == "result")' 2>/dev/null)"; then
  log "speedtest falhou (rc=$RC); nada enviado"
  exit 1
fi

ISP="$(printf '%s' "$JSON" | jq -r '.isp // ""')"
if [ -n "$EXPECT_ISP" ] && ! printf '%s' "$ISP" | grep -Eiq -- "$EXPECT_ISP"; then
  log "teste saiu pelo provedor '$ISP', esperado /$EXPECT_ISP/ - verifique a rota; nada enviado"
  exit 1
fi

if zabbix_sender -z "$ZBX_SERVER" -s "$ZBX_HOST" -k "$KEY" -o "$JSON" >/dev/null 2>&1; then
  DL="$(printf '%s' "$JSON" | jq -r '(.download.bandwidth*8/1000000|floor)')"
  UL="$(printf '%s' "$JSON" | jq -r '(.upload.bandwidth*8/1000000|floor)')"
  log "enviado: $ISP download ${DL} Mbps upload ${UL} Mbps"
else
  log "ERRO: zabbix_sender falhou (porta 10051 de $ZBX_SERVER acessivel? host '$ZBX_HOST' existe?)"
  exit 1
fi