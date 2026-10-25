#!/usr/bin/env bash
# vps-check.sh — проверка арендованного сервера/VPS (и любого Linux-хоста) перед покупкой и установкой Thin Web.
# Репозиторий: https://github.com/stadnikartem/hdd-test
#
#   curl -fsSL https://raw.githubusercontent.com/stadnikartem/hdd-test/main/vps-check.sh | sudo bash -s -- --install
#   sudo ./vps-check.sh [--dir /путь/на/нужном/диске] [--size 2G] [--quick] [--install] [--need ГБ] [--no-net]
#
# Что проверяет: ОС и совместимость с панелью, процессор (в т.ч. «воровство» CPU
# соседями), память, диск (последовательная скорость, случайный доступ, fsync),
# сеть (пинг, скачивание, отдача, доступность GitHub/Docker/Telegram/зеркал),
# кодирование видео ffmpeg. В конце — сводка OK/WARN/FAIL.
# Ничего не ставит без --install и не оставляет файлов (тестовые удаляются).

set -u
export LC_ALL=C

DIR=/var/tmp
SIZE=2G
QUICK=0
NEED=900
INSTALL=0
NONET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR=$2; shift 2 ;;
    --size) SIZE=$2; shift 2 ;;
    --quick) QUICK=1; shift ;;
    --need) NEED=$2; shift 2 ;;
    --install) INSTALL=1; shift ;;
    --no-net) NONET=1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "неизвестный параметр: $1"; exit 2 ;;
  esac
done
[ "$QUICK" = 1 ] && SIZE=512M

if [ -t 1 ]; then CG=$'\e[32m'; CY=$'\e[33m'; CR=$'\e[31m'; B=$'\e[1m'; N=$'\e[0m'; else CG=; CY=; CR=; B=; N=; fi
RES=()   # "STATUS|name|detail"
have() { command -v "$1" >/dev/null 2>&1; }
sec()  { printf '\n%s== %s ==%s\n' "$B" "$1" "$N"; }
add()  { RES+=("$1|$2|$3"); local c=$CG; [ "$1" = WARN ] && c=$CY; [ "$1" = FAIL ] && c=$CR
         printf '  %s%-4s%s %-28s %s\n' "$c" "$1" "$N" "$2" "$3"; }
info() { printf '       %-28s %s\n' "$1" "$2"; }
# cmp_ge value ok warn name detail   (больше — лучше)
rate_ge() { awk -v v="$1" -v o="$2" -v w="$3" 'BEGIN{print (v>=o)?"OK":((v>=w)?"WARN":"FAIL")}'; }
# rate_le (меньше — лучше)
rate_le() { awk -v v="$1" -v o="$2" -v w="$3" 'BEGIN{print (v<=o)?"OK":((v<=w)?"WARN":"FAIL")}'; }

TMP=$(mktemp -d "$DIR/.vpscheck.XXXXXX" 2>/dev/null) || { echo "нет записи в $DIR"; exit 1; }
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

if [ "$INSTALL" = 1 ] && have apt-get; then
  sec "Установка утилит"
  apt-get update -qq && apt-get install -y -qq fio curl python3 ffmpeg iproute2 >/dev/null && echo "  готово"
fi

# ───────────────────────────── Система ─────────────────────────────
sec "Система"
. /etc/os-release 2>/dev/null
OSN="${PRETTY_NAME:-unknown}"
ARCH=$(uname -m)
VIRT=$(systemd-detect-virt 2>/dev/null || echo "?")
info "ОС" "$OSN"
info "Ядро / архитектура" "$(uname -r) / $ARCH"
info "Виртуализация" "$VIRT"
case "${ID:-}:${VERSION_ID:-}" in
  debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) add OK "ОС поддерживается" "$OSN" ;;
  *) add WARN "ОС поддерживается" "$OSN — нужен Debian 12/13 или Ubuntu 22.04/24.04 (можно переустановить)" ;;
esac
case "$ARCH" in x86_64|aarch64) add OK "Архитектура" "$ARCH" ;; *) add FAIL "Архитектура" "$ARCH — нужен amd64/arm64" ;; esac
case "$VIRT" in
  openvz|lxc|lxc-libvirt|docker|podman) add WARN "Тип виртуализации" "$VIRT — контейнер: нет своего ядра, WireGuard/ffmpeg/модули могут не работать" ;;
  none) add OK "Тип виртуализации" "физический сервер" ;;
  *) add OK "Тип виртуализации" "$VIRT" ;;
esac
have systemctl && add OK "systemd" "есть" || add FAIL "systemd" "нет — панель ставится как systemd-сервис"
[ "$(id -u)" = 0 ] && add OK "Права" "root" || add WARN "Права" "не root — часть проверок пропущена"

# ───────────────────────────── Процессор ─────────────────────────────
sec "Процессор"
NCPU=$(nproc)
MODEL=$(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ *//')
[ -z "$MODEL" ] && MODEL=$(lscpu 2>/dev/null | awk -F: '/Model name/{print $2; exit}' | sed 's/^ *//')
info "Модель" "${MODEL:-?}"
info "vCPU" "$NCPU"
[ "$NCPU" -ge 2 ] && add OK "Ядер (vCPU)" "$NCPU" || add WARN "Ядер (vCPU)" "$NCPU — мало для фото/поиска дубликатов"
if grep -qw aes /proc/cpuinfo 2>/dev/null; then add OK "AES-NI" "есть"; else add WARN "AES-NI" "нет — TLS/шифрование бэкапов будут медленнее"; fi

# Нагрузочный тест: sha256 в один поток и во все потоки, плюс замер steal.
cpu_bench() {
python3 - "$1" <<'PY'
import hashlib, sys, time, multiprocessing as mp
def work(_):
    b = b"x" * 1048576
    t = time.time(); n = 0
    while time.time() - t < 4:
        hashlib.sha256(b).digest(); n += 1
    return n / (time.time() - t)
if __name__ == "__main__":
    k = int(sys.argv[1])
    with mp.Pool(k) as p:
        r = p.map(work, range(k))
    print("%.0f" % sum(r))
PY
}
steal_pct() {
  awk '/^cpu /{print $9, $2+$3+$4+$5+$6+$7+$8+$9}' /proc/stat
}
if have python3; then
  S1=$(cpu_bench 1); info "sha256, 1 поток" "${S1:-?} МБ/с"
  read -r st0 tt0 < <(steal_pct)
  SN=$(cpu_bench "$NCPU"); info "sha256, $NCPU потоков" "${SN:-?} МБ/с"
  read -r st1 tt1 < <(steal_pct)
  STEAL=$(awk -v a="$st0" -v b="$st1" -v c="$tt0" -v d="$tt1" 'BEGIN{ if (d>c) printf "%.1f", (b-a)*100/(d-c); else print 0 }')
  r=$(rate_ge "${S1:-0}" 300 150); add "$r" "Скорость одного ядра" "${S1:-?} МБ/с (sha256; хорошо ≥300, сервер на Xeon E3 ≈ 350–500)"
  if [ "$NCPU" -gt 1 ]; then
    eff=$(awk -v a="${S1:-1}" -v b="${SN:-0}" -v n="$NCPU" 'BEGIN{printf "%.0f", b*100/(a*n)}')
    r=$(rate_ge "$eff" 80 50); add "$r" "Масштабирование по ядрам" "${eff}% от идеала (низкое = ядра делят с соседями)"
  fi
  r=$(rate_le "$STEAL" 3 10); add "$r" "Steal (воровство CPU)" "${STEAL}% во время теста"
else
  add WARN "Тест CPU" "нет python3 — пропущен (запустите с --install)"
fi

# ───────────────────────────── Память ─────────────────────────────
sec "Память"
MEM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
SWAP_MB=$(awk '/SwapTotal/{printf "%d", $2/1024}' /proc/meminfo)
info "ОЗУ / swap" "${MEM_MB} МБ / ${SWAP_MB} МБ"
r=$(rate_ge "$MEM_MB" 3500 900); add "$r" "Объём ОЗУ" "${MEM_MB} МБ (минимум 1 ГБ, комфортно ≥4 ГБ)"
if have python3; then
  MB=$(python3 - <<'PY'
import time
n = 256 * 1024 * 1024
a = bytearray(n)
t = time.time()
for _ in range(4):
    b = bytes(a)
    del b
d = time.time() - t
print("%.0f" % (4 * n / 1048576 / d))
PY
)
  info "Скорость памяти" "${MB:-?} МБ/с (копирование в python; для сравнения серверов, не оценивается)"
fi

# ───────────────────────────── Диск ─────────────────────────────
sec "Диск  ($DIR, тестовый файл $SIZE)"
FREE_GB=$(df -Pk "$DIR" | awk 'NR==2{printf "%d", $4/1048576}')
FSTYPE=$(df -PT "$DIR" | awk 'NR==2{print $2}')
DEV=$(df -P "$DIR" | awk 'NR==2{print $1}')
info "Раздел" "$DEV ($FSTYPE), свободно ${FREE_GB} ГБ"
ROT=$(lsblk -dno ROTA "$(lsblk -no PKNAME "$DEV" 2>/dev/null | head -1 | sed 's#^#/dev/#')" 2>/dev/null | head -1)
[ "$ROT" = 1 ] && info "Тип" "HDD (rotational)" || { [ "$ROT" = 0 ] && info "Тип" "SSD/NVMe (или виртуальный диск)"; }
r=$(rate_ge "$FREE_GB" "$NEED" $((NEED/9))); add "$r" "Свободно на диске" "${FREE_GB} ГБ"
lsblk -dno NAME,SIZE,ROTA,TYPE 2>/dev/null | sed 's/^/         /' | head -8

# Реальные цифры для HDD и SSD разные, поэтому критерии мягкие: цель — поймать совсем плохой диск.
if have fio; then
  FIO="fio --directory=$TMP --size=$SIZE --direct=1 --ioengine=libaio --group_reporting --minimal --terse-version=3"
  fio_run() { # name rw bs iodepth runtime extra...
    local name=$1 rw=$2 bs=$3 qd=$4 rt=$5; shift 5
    $FIO --name="$name" --filename="$TMP/fio.$name" --rw="$rw" --bs="$bs" --iodepth="$qd" \
         --time_based --runtime="$rt" --ramp_time=2 "$@" 2>/dev/null
  }
  RT=15; [ "$QUICK" = 1 ] && RT=6
  # terse v3: поля 7=read bw KB/s, 8=read iops, 48=write bw, 49=write iops; 40=clat p99 write (usec) смещается, поэтому берём простые
  W=$(fio_run seqw write 1M 8 $RT | awk -F';' '{printf "%.0f", $48/1024}')
  R=$(fio_run seqr read 1M 8 $RT | awk -F';' '{printf "%.0f", $7/1024}')
  rm -f "$TMP"/fio.seq*
  RR1=$(fio_run rr1 randread 4k 1 $RT | awk -F';' '{printf "%.0f", $8}')
  RW1=$(fio_run rw1 randwrite 4k 1 $RT | awk -F';' '{printf "%.0f", $49}')
  RR32=$(fio_run rr32 randread 4k 32 $RT | awk -F';' '{printf "%.0f", $8}')
  rm -f "$TMP"/fio.rr* "$TMP"/fio.rw*
  FS=$(fio_run fsync write 4k 1 $RT --fsync=1 | awk -F';' '{printf "%.0f", $49}')
  rm -f "$TMP"/fio.fsync
  r=$(rate_ge "${W:-0}" 60 15);  add "$r" "Запись последовательная" "${W:-?} МБ/с (HDD обычно 80–200)"
  r=$(rate_ge "${R:-0}" 60 15);  add "$r" "Чтение последовательное" "${R:-?} МБ/с"
  r=$(rate_ge "${RR1:-0}" 100 40); add "$r" "Случайное чтение 4K, QD1" "${RR1:-?} IOPS (лента «Фото», миниатюры; HDD ≈ 80–200, SSD >5000)"
  r=$(rate_ge "${RR32:-0}" 200 80); add "$r" "Случайное чтение 4K, QD32" "${RR32:-?} IOPS"
  r=$(rate_ge "${RW1:-0}" 100 40); add "$r" "Случайная запись 4K, QD1" "${RW1:-?} IOPS"
  r=$(rate_ge "${FS:-0}" 100 30);  add "$r" "fsync-записей в секунду" "${FS:-?} (sqlite/база панели; <30 — будут тормоза)"
else
  # запасной вариант без fio
  echo "  (fio не найден — упрощённый тест dd; для полного: --install)"
  WS=$(dd if=/dev/zero of="$TMP/dd" bs=1M count=1024 oflag=direct 2>&1 | awk '/copied/{print $(NF-1), $NF}')
  info "dd запись" "$WS"
  RS=$(dd if="$TMP/dd" of=/dev/null bs=1M iflag=direct 2>&1 | awk '/copied/{print $(NF-1), $NF}')
  info "dd чтение" "$RS"
  add WARN "Тест диска" "только dd; случайный доступ и fsync не проверены"
fi

# ───────────────────────────── Сеть ─────────────────────────────
if [ "$NONET" = 0 ]; then
  sec "Сеть"
  IP4=$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null)
  IP6=$(curl -6 -fsS --max-time 4 https://api64.ipify.org 2>/dev/null)
  info "Публичный IPv4" "${IP4:-нет}"
  info "IPv6" "${IP6:-нет}"
  [ -n "$IP4" ] && add OK "Публичный IPv4" "$IP4" || add FAIL "Публичный IPv4" "не определён"
  if [ -n "$IP4" ]; then
    GEO=$(curl -fsS --max-time 6 "http://ip-api.com/line/$IP4?fields=country,city,isp,as&lang=ru" 2>/dev/null | paste -sd, -)
    [ -n "$GEO" ] && info "Расположение / оператор" "$GEO"
  fi
  # входящие: эти порты нужны панели
  if have ss; then
    BUSY=$(ss -ltn 2>/dev/null | awk 'NR>1{n=split($4,a,":"); print a[n]}' | grep -E '^(80|443)$' | sort -u | paste -sd, -)
    [ -n "$BUSY" ] && add WARN "Порты 80/443" "уже заняты: $BUSY" || add OK "Порты 80/443" "свободны"
  fi
  # задержка (пинг)
  ping_ms() { ping -c 4 -W 2 -q "$1" 2>/dev/null | awk -F'/' '/^rtt|^round-trip/{printf "%.0f", $5}'; }
  if have ping; then
    for h in ya.ru 77.88.8.8 vk.com github.com 1.1.1.1; do
      ms=$(ping_ms "$h")
      if [ -z "$ms" ]; then info "ping $h" "нет ответа"; continue; fi
      info "ping $h" "${ms} мс"
      [ "$h" = ya.ru ] && { r=$(rate_le "$ms" 25 60); add "$r" "Задержка до ya.ru" "${ms} мс (Москва ≈ 1–15; СПб/ЕС 20–50)"; }
    done
  fi
  # доступность сервисов, которые нужны при установке и работе
  chk() { code=$(curl -4 -s -o /dev/null -w '%{http_code}' --max-time 8 "$2" 2>/dev/null); case "$code" in 2*|3*|401|403|404|405) add OK "$1" "доступен ($code)";; *) add WARN "$1" "недоступен (код ${code:-нет})";; esac; }
  chk "GitHub (установка панели)" https://github.com
  chk "raw.githubusercontent.com" https://raw.githubusercontent.com
  chk "Зеркало Debian" https://deb.debian.org
  chk "pypi.org (pip)" https://pypi.org
  chk "Telegram API (уведомления)" https://api.telegram.org
  chk "Docker Hub" https://registry-1.docker.io/v2/

  # скорость (Cloudflare — быстрый CDN; HTTP-код 000 = недоступно)
  dl() { curl -4 -s -o /dev/null -w '%{speed_download}' --max-time "${2:-12}" "$1" 2>/dev/null | awk '{printf "%.0f", $1*8/1000000}'; }
  # Cloudflare иногда отдаёт 403 на большие размеры — берём 25 МБ и берём лучший из двух источников
  DLM=$(dl "https://speed.cloudflare.com/__down?bytes=25000000" 12)
  YA=$(dl "https://mirror.yandex.ru/debian/ls-lR.gz" 12)
  info "Скачивание Cloudflare / mirror.yandex.ru" "${DLM:-0} / ${YA:-0} Мбит/с"
  BEST=$(awk -v a="${DLM:-0}" -v b="${YA:-0}" 'BEGIN{print (a>b)?a:b}')
  r=$(rate_ge "$BEST" 80 30); add "$r" "Скачивание (лучшее из двух)" "${BEST} Мбит/с"
  head -c 30000000 /dev/zero > "$TMP/up.bin"
  UPM=$(curl -4 -s -o /dev/null -w '%{speed_upload}' --max-time 15 -X POST --data-binary @"$TMP/up.bin" https://speed.cloudflare.com/__up 2>/dev/null | awk '{printf "%.0f", $1*8/1000000}')
  r=$(rate_ge "${UPM:-0}" 50 20); add "$r" "Отдача (Cloudflare)" "${UPM:-0} Мбит/с (просмотр фото/видео из дома)"
  rm -f "$TMP/up.bin"
  # потери пакетов на длинном пинге
  if have ping && [ "$QUICK" = 0 ]; then
    LOSS=$(ping -c 30 -i 0.3 -q 77.88.8.8 2>/dev/null | awk -F', ' '/packet loss/{gsub("%.*","",$3); print $3}')
    [ -n "$LOSS" ] && { r=$(rate_le "$LOSS" 0 2); add "$r" "Потери пакетов (30 пингов)" "${LOSS}%"; }
  fi
fi

# ───────────────────────────── ffmpeg ─────────────────────────────
sec "Видео (ffmpeg)"
if have ffmpeg; then
  T0=$(date +%s.%N)
  ffmpeg -v error -f lavfi -i testsrc2=size=1920x1080:rate=30 -t 8 -c:v libx264 -preset veryfast -f null - 2>/dev/null
  T1=$(date +%s.%N)
  X=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.1f", 8/(b-a)}')
  r=$(rate_ge "$X" 1.5 0.6); add "$r" "Кодирование 1080p (x264)" "${X}× реального времени (миниатюры/превью видео)"
  T0=$(date +%s.%N)
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ffmpeg -v error -f lavfi -i testsrc2=size=1920x1080:rate=1 -frames:v 1 -vf scale=9:8,format=gray -f rawvideo - >/dev/null 2>&1
  done
  T1=$(date +%s.%N)
  P=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.0f", 10/(b-a)}')
  info "Запусков ffmpeg/с" "$P (поиск похожих фото)"
else
  add WARN "ffmpeg" "не установлен — нужен для миниатюр видео и поиска похожих (apt install ffmpeg)"
fi

# ───────────────────────────── Прочее ─────────────────────────────
sec "Прочее"
if have timedatectl; then
  SY=$(timedatectl 2>/dev/null | awk -F': ' '/synchronized/{print $2}')
  [ "$SY" = yes ] && add OK "Синхронизация времени" "включена" || add WARN "Синхронизация времени" "выключена (для TLS/2FA включите NTP)"
fi
if [ -r /proc/sys/net/ipv4/ip_forward ]; then info "ip_forward" "$(cat /proc/sys/net/ipv4/ip_forward)"; fi
if [ -c /dev/net/tun ]; then add OK "/dev/net/tun" "есть (VPN-часть панели)"; else add WARN "/dev/net/tun" "нет — VPN-функции панели не заработают (включите TUN у хостера)"; fi
if modprobe -n wireguard >/dev/null 2>&1 || [ -d /sys/module/wireguard ]; then add OK "WireGuard" "поддерживается ядром"; else add WARN "WireGuard" "модуль недоступен"; fi
if have smartctl && [ "$VIRT" = none ]; then
  for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do
    h=$(smartctl -H "/dev/$d" 2>/dev/null | awk -F: '/overall-health|SMART Health/{print $2}')
    [ -n "$h" ] && info "SMART /dev/$d" "$h"
  done
fi

# ───────────────────────────── Итог ─────────────────────────────
sec "Итог"
ok=0; w=0; f=0
for l in "${RES[@]}"; do case "${l%%|*}" in OK) ok=$((ok+1));; WARN) w=$((w+1));; FAIL) f=$((f+1));; esac; done
printf '  %sOK: %d%s   %sWARN: %d%s   %sFAIL: %d%s\n' "$CG" "$ok" "$N" "$CY" "$w" "$N" "$CR" "$f" "$N"
if [ "$f" -gt 0 ]; then
  echo "  Проблемы (FAIL):"; for l in "${RES[@]}"; do [ "${l%%|*}" = FAIL ] && IFS='|' read -r _ n d <<<"$l" && echo "   - $n: $d"; done
fi
if [ "$w" -gt 0 ]; then
  echo "  Замечания (WARN):"; for l in "${RES[@]}"; do [ "${l%%|*}" = WARN ] && IFS='|' read -r _ n d <<<"$l" && echo "   - $n: $d"; done
fi
echo
if [ "$f" -gt 0 ]; then echo "  Вердикт: ${CR}не брать / требует решения${N}"
elif [ "$w" -gt 2 ]; then echo "  Вердикт: ${CY}можно, но есть слабые места${N}"
else echo "  Вердикт: ${CG}подходит${N}"; fi
echo "  Не проверяется скриптом: лимит трафика и скорость порта по договору, надёжность диска (RAID), поддержка."
