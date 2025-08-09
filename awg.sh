#!/bin/ash
set -e

AWG_URL="${AWG_URL:-https://github.com/amnezia-vpn/amneziawg-go/releases/latest/download/amneziawg-go_linux_mipsle}"
AWG_BIN="/usr/bin/amneziawg"
AWG_DIR="/etc/amneziawg"
AWG_IF="awg0"
AWG_CONF="$AWG_DIR/$AWG_IF.conf"
INIT="/etc/init.d/amneziawg"
LOG="/var/log/amneziawg.log"
EDITOR="${EDITOR:-vi}"

msg(){ echo "[$(date +'%F %T')] $*"; }
wan_if(){ ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev"){print $(i+1); exit}}' || echo wan; }
need(){ command -v "$1" >/dev/null 2>&1; }
opkg_i(){ opkg install -V0 "$@" >/dev/null; }

ensure_base(){
  msg "Пакеты: curl, ca-bundle, ip-full, kmod-tun, dnsmasq-full"
  opkg update >/dev/null
  opkg_i curl ca-bundle ip-full kmod-tun dnsmasq-full
  need ping || opkg_i iputils-ping || true
  install -d "$AWG_DIR"
}

install_or_update(){
  ensure_base
  if [ ! -x "$AWG_BIN" ]; then
    msg "Скачиваю amneziawg-go (mipsle)"
    curl -fsSL "$AWG_URL" -o "$AWG_BIN"
    chmod +x "$AWG_BIN"
  else
    msg "Проверка обновлений бинаря"
    TMP="$(mktemp)"; curl -fsSL "$AWG_URL" -o "$TMP"
    if ! cmp -s "$TMP" "$AWG_BIN"; then
      mv "$TMP" "$AWG_BIN"; chmod +x "$AWG_BIN"
      msg "Бинарь обновлён"
    else
      rm -f "$TMP"; msg "Уже последняя версия"
    fi
  fi

  if [ ! -s "$AWG_CONF" ]; then
    cat > "$AWG_CONF" <<'EOF'
# ВСТАВЬ СВОЙ КОНФИГ AmneziaWG (формат .conf) НИЖЕ ЭТИХ СТРОК:
# [Interface]
# PrivateKey = <CLIENT_PRIVATE>
# Address = 10.8.1.2/32
# DNS = 1.1.1.1, 1.0.0.1
# MTU = 1360
#
# [Peer]
# PublicKey = <SERVER_PUBLIC>
# PresharedKey = <PSK>
# Endpoint = X.X.X.X:PORT
# AllowedIPs = 0.0.0.0/0, ::/0
# PersistentKeepalive = 25
#
# Jc = 4
# Jmin = 10
# Jmax = 50
# S1 = 145
# S2 = 73
# H1 = 437130762
# H2 = 1548472397
# H3 = 781694470
# H4 = 493132402
EOF
    msg "Создан шаблон конфига: $AWG_CONF"
    $EDITOR "$AWG_CONF"
  fi

  msg "Сервис автозапуска"
  cat > "$INIT" <<'EOF'
#!/bin/ash /etc/rc.common
START=99
USE_PROCD=1
start_service(){
  procd_open_instance
  procd_set_param command /usr/bin/amneziawg up /etc/amneziawg/awg0.conf
  procd_set_param respawn 5 10 0
  procd_close_instance
}
stop_service(){ /usr/bin/amneziawg down awg0 2>/dev/null || true; }
status_service(){
  echo "=== AmneziaWG status ==="
  ip -4 addr show awg0 2>/dev/null || echo "awg0 down"
  ip -6 addr show awg0 2>/dev/null | sed 's/^/ /'
  echo -n "WAN: "; ip -4 route get 1.1.1.1 2>/dev/null | head -1
  echo -n "VPN IPv4: "; command -v curl >/dev/null && curl -4 -s ifconfig.me || echo "curl нет"
}
EOF
  chmod +x "$INIT"

  msg "Интерфейс $AWG_IF и firewall"
  uci -q delete network.$AWG_IF
  uci set network.$AWG_IF=interface
  uci set network.$AWG_IF.ifname="$AWG_IF"
  uci set network.$AWG_IF.proto='none'
  uci set network.$AWG_IF.metric='10'
  uci commit network

  if ! uci -q show firewall.wan.network | grep -q "'$AWG_IF'"; then
    uci add_list firewall.wan.network="$AWG_IF"
    uci commit firewall
  fi

  msg "DNS: Cloudflare через dnsmasq (можно переключить в меню)"
  uci set dhcp.@dnsmasq[0].noresolv='1'
  uci set dhcp.@dnsmasq[0].server='1.1.1.1'
  uci add_list dhcp.@dnsmasq[0].server='1.0.0.1'
  uci commit dhcp

  apply_fw
  msg "Готово. Запусти VPN в меню или: /etc/init.d/amneziawg start"
}

apply_fw(){
  /etc/init.d/network reload >/dev/null 2>&1 || true
  /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
  /etc/init.d/firewall restart >/dev/null 2>&1 || true
}

edit_conf(){ $EDITOR "$AWG_CONF"; }

toggle_autostart(){
  if /etc/init.d/amneziawg enabled 2>/dev/null; then
    /etc/init.d/amneziawg disable; msg "Автозапуск: выключен"
  else
    /etc/init.d/amneziawg enable; msg "Автозапуск: включен"
  fi
}

force_dns_on(){
  LAN_IP="$(uci -q get network.lan.ipaddr || echo 192.168.1.1)"; LAN_IP="${LAN_IP%%/*}"
  uci -q delete firewall.force_dns
  uci set firewall.force_dns=redirect
  uci set firewall.force_dns.name='Force-DNS-over-router'
  uci set firewall.force_dns.src='lan'
  uci set firewall.force_dns.src_dport='53'
  uci set firewall.force_dns.proto='tcp udp'
  uci set firewall.force_dns.dest_ip="$LAN_IP"
  uci set firewall.force_dns.dest_port='53'
  uci commit firewall
  apply_fw; msg "Форс-DNS: включён (LAN -> $LAN_IP:53)"
}

force_dns_off(){
  uci -q delete firewall.force_dns && uci commit firewall || true
  apply_fw; msg "Форс-DNS: выключен"
}

optimize_mtu(){
  IF="$(wan_if)"
  TARGET="${1:-1.1.1.1}"
  MTU=1420
  msg "Подбор MTU на $IF к $TARGET"
  if ping -c1 -W1 -M do -s $((MTU-28)) "$TARGET" >/dev/null 2>&1; then
    while ! ping -c1 -W1 -M do -s $((MTU-28)) "$TARGET" >/dev/null 2>&1; do MTU=$((MTU-10)); done
  else
    MTU=1360
  fi
  if grep -q '^MTU' "$AWG_CONF" 2>/dev/null; then
    sed -i "s/^MTU.*/MTU = $MTU/" "$AWG_CONF"
  else
    sed -i "/^\[Interface\]/a MTU = $MTU" "$AWG_CONF"
  fi
  uci -q delete firewall.mss_clamp
  uci set firewall.mss_clamp=rule
  uci set firewall.mss_clamp.name='MSS-Clamp'
  uci set firewall.mss_clamp.src='lan'
  uci set firewall.mss_clamp.proto='tcp'
  uci set firewall.mss_clamp.target='TCPMSS'
  uci set firewall.mss_clamp.set_mss="$((MTU-40))"
  uci commit firewall
  apply_fw
  msg "MTU=$MTU, TCPMSS=$(($MTU-40))"
}

start_vpn(){ /etc/init.d/amneziawg start && msg "VPN: старт"; }
stop_vpn(){ /etc/init.d/amneziawg stop && msg "VPN: стоп" || true; }
restart_vpn(){ /etc/init.d/amneziawg restart && msg "VPN: рестарт" || true; }
status_vpn(){ /etc/init.d/amneziawg status || true; }

test_ip(){
  need curl || { msg "curl не установлен"; return 1; }
  IPv4="$(curl -4 -s ifconfig.me || echo -)"; IPv6="$(curl -6 -s ifconfig.me || echo -)"
  msg "Публичный IPv4: $IPv4"
  msg "Публичный IPv6: $IPv6"
  msg "Трасса до 1.1.1.1"; (command -v traceroute >/dev/null && traceroute -n -m 8 1.1.1.1) || ip route get 1.1.1.1
}

speed_test(){
  URL="${1:-http://speedtest.tele2.net/10MB.zip}"
  need wget || opkg_i wget-ssl
  msg "Скорость (wget -> /dev/null): $URL"
  wget -O /dev/null "$URL"
}

uninstall_all(){
  stop_vpn || true
  /etc/init.d/amneziawg disable || true
  rm -f "$INIT" "$AWG_BIN"
  uci -q delete network.$AWG_IF; uci commit network
  uci -q delete firewall.force_dns
  uci -q delete firewall.mss_clamp; uci commit firewall
  apply_fw
  msg "Удалено. Конфиг оставлен: $AWG_CONF"
}

menu(){
  while :; do
    echo; echo "=== AmneziaWG Manager ==="
    echo "1) Установить/обновить amneziawg-go"
    echo "2) Редактировать конфиг ($AWG_CONF)"
    echo "3) Запустить VPN"
    echo "4) Остановить VPN"
    echo "5) Рестарт VPN"
    echo "6) Статус"
    echo "7) Подобрать MTU"
    echo "8) Автозапуск On/Off"
    echo "9) Форс-DNS On"
    echo "10) Форс-DNS Off"
    echo "11) Проверить IP/маршрут"
    echo "12) Тест скорости"
    echo "13) Удалить всё (без удаления $AWG_CONF)"
    echo "0) Выход"
    printf "> "; read -r a
    case "$a" in
      1) install_or_update ;;
      2) edit_conf ;;
      3) start_vpn ;;
      4) stop_vpn ;;
      5) restart_vpn ;;
      6) status_vpn ;;
      7) optimize_mtu ;;
      8) toggle_autostart ;;
      9) force_dns_on ;;
      10) force_dns_off ;;
      11) test_ip ;;
      12) speed_test ;;
      13) uninstall_all ;;
      0) exit 0 ;;
      *) echo "Неизвестный выбор";;
    esac
  done
}

menu
