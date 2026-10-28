#!/usr/bin/env sh
if [ "$(id -u)" != "0" ]; then
	echo "[watersocks] 需要 root 运行" >&2
	exit 1
fi
if ! command -v bash >/dev/null 2>&1; then
	echo "[watersocks] 没有 bash,正在安装..." >&2
	if command -v apk >/dev/null 2>&1; then
		apk add --no-cache bash >&2 || { echo "[watersocks] apk add bash 失败" >&2; exit 1; }
	elif command -v apt-get >/dev/null 2>&1; then
		{ apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y bash; } >&2 || { echo "[watersocks] apt-get 安装 bash 失败" >&2; exit 1; }
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y bash >&2 || { echo "[watersocks] dnf 安装 bash 失败" >&2; exit 1; }
	elif command -v yum >/dev/null 2>&1; then
		yum install -y bash >&2 || { echo "[watersocks] yum 安装 bash 失败" >&2; exit 1; }
	else
		echo "[watersocks] 没有 bash,也找不到包管理器" >&2
		exit 1
	fi
fi
WATERSOCKS_SELF=$(mktemp 2>/dev/null || echo "/tmp/watersocks.$$")
cat > "$WATERSOCKS_SELF" <<'WATERSOCKS_BODY_END'
set -euo pipefail

if [[ "${WATERSOCKS_SELF_TMP:-}" = "1" ]]; then
    rm -f "$0" 2>/dev/null || true
fi

SOCKS_PORT="${SOCKS_PORT:-$((53000 + RANDOM % 1001))}"
USER_PREFIX="${USER_PREFIX:-prx}"
PROBE_BASE="${WATERPROBE_BASE:-https://raw.githubusercontent.com/impyf104/waterprobe/main}"
FORCE=0
NO_PROBE=0
NO_START=0
declare -a IPS=()

usage() {
    cat >&2 <<'USAGE_END'
usage: watersocks.sh [--port N] [--user-prefix P] [--ip A]... [--force] [--no-probe] [--no-start] [--probe-base URL]
USAGE_END
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) SOCKS_PORT="$2"; shift 2 ;;
        --user-prefix) USER_PREFIX="$2"; shift 2 ;;
        --ip) IPS+=("$2"); shift 2 ;;
        --force) FORCE=1; shift ;;
        --no-probe) NO_PROBE=1; shift ;;
        --no-start) NO_START=1; shift ;;
        --probe-base) PROBE_BASE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[watersocks] 未知参数: $1" >&2; usage; exit 1 ;;
    esac
done

if ! [[ "$SOCKS_PORT" =~ ^[0-9]+$ ]] || (( SOCKS_PORT < 1 || SOCKS_PORT > 65535 )); then
    echo "[watersocks] 端口不合法: $SOCKS_PORT" >&2
    exit 1
fi

log() { printf '[watersocks] %s\n' "$*" >&2; }
err() { printf '[watersocks] 错误: %s\n' "$*" >&2; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t watersocks)
trap 'rm -rf "$WORK"' EXIT


DISTRO=other
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    case " ${ID:-} ${ID_LIKE:-} " in
        *" alpine "*) DISTRO=alpine ;;
        *" debian "*|*" ubuntu "*) DISTRO=debian ;;
        *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*|*" almalinux "*) DISTRO=rhel ;;
    esac
fi

case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) err "不支持的架构 $(uname -m)"; exit 1 ;;
esac
log "发行版: $DISTRO  架构: $ARCH"


pkg_install() {
    case "$DISTRO" in
        alpine) apk add --no-cache "$@" >&2 ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y >&2 && apt-get install -y "$@" >&2 ;;
        rhel)
            if command -v dnf >/dev/null 2>&1; then dnf install -y "$@" >&2; else yum install -y "$@" >&2; fi ;;
        *) return 1 ;;
    esac
}

ensure_base_tools() {
    local -a need=()
    command -v curl >/dev/null 2>&1 || need+=(curl)
    command -v openssl >/dev/null 2>&1 || need+=(openssl)
    command -v tar >/dev/null 2>&1 || need+=(tar)
    if ! command -v ip >/dev/null 2>&1; then
        if [[ "$DISTRO" = rhel ]]; then need+=(iproute); else need+=(iproute2); fi
    fi
    if [[ ! -s /etc/ssl/certs/ca-certificates.crt && ! -s /etc/pki/tls/certs/ca-bundle.crt ]]; then
        need+=(ca-certificates)
    elif [[ "$DISTRO" = alpine || "$DISTRO" = debian ]] && [[ ${#need[@]} -gt 0 ]]; then
        need+=(ca-certificates)
    fi
    if [[ ${#need[@]} -eq 0 ]]; then
        return 0
    fi
    if [[ "$DISTRO" = other ]]; then
        err "缺少工具: ${need[*]};未识别的发行版,请先自行安装"
        exit 1
    fi
    log "安装基础工具: ${need[*]}"
    pkg_install "${need[@]}" || { err "安装基础工具失败: ${need[*]}"; exit 1; }
}

ensure_base_tools


PROBE_RC=-1
run_probe() {
    local bin="$WORK/waterprobe"
    log "下载 waterprobe: ${PROBE_BASE}/waterprobe-linux-${ARCH}"
    if ! curl -fsSL --max-time 60 "${PROBE_BASE}/waterprobe-linux-${ARCH}" -o "$bin"; then
        if [[ $FORCE -eq 1 ]]; then
            log "waterprobe 下载失败,--force:不探测,继续安装"
            return 0
        fi
        err "waterprobe 下载失败(--force 可跳过探测强制安装)"
        exit 2
    fi
    chmod +x "$bin"
    local rc=0
    "$bin" >&2 || rc=$?
    PROBE_RC=$rc
    if [[ $rc -eq 3 ]]; then
        if [[ $FORCE -eq 1 ]]; then
            log "两个站都不可达,--force:照样安装"
            return 0
        fi
        log "两个站都不可达,不安装代理(--force 可强制)"
        exit 3
    fi
    if [[ $rc -gt 3 ]]; then
        if [[ $FORCE -eq 1 ]]; then
            log "waterprobe 异常退出($rc),--force:继续"
            return 0
        fi
        err "waterprobe 异常退出($rc)(--force 可跳过)"
        exit 2
    fi
}

if [[ $NO_PROBE -eq 1 ]]; then
    log "跳过出口探测(--no-probe)"
else
    run_probe
fi

probe_verdict() {
    if [[ $PROBE_RC -lt 0 || $PROBE_RC -gt 3 ]]; then
        echo "未探测"
        return
    fi
    local kr="KR 可用" glb="GLB 可用"
    (( PROBE_RC & 1 )) && kr="KR 不可用"
    (( PROBE_RC & 2 )) && glb="GLB 不可用"
    echo "$kr / $glb"
}


install_singbox_tarball() {
    local tag=""
    tag=$(curl -fsSL --max-time 20 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null \
        | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"(v[^"]+)".*/\1/p' | head -n1) || true
    if [[ -z "$tag" ]]; then
        tag=$(curl -fsSL --max-time 20 -o /dev/null -w '%{url_effective}' https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null \
            | sed -nE 's#.*/tag/(v[^/]+)$#\1#p') || true
    fi
    if [[ -z "$tag" ]]; then
        err "取不到 sing-box 最新版本号"
        exit 1
    fi
    local ver="${tag#v}"
    local base="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${ver}-linux-${ARCH}"
    local url="${base}.tar.gz"
    if ls /lib/ld-musl-* >/dev/null 2>&1; then
        url="${base}-musl.tar.gz"
    fi
    log "下载 sing-box ${tag}: $url"
    if ! curl -fsSL --max-time 300 "$url" -o "$WORK/sing-box.tar.gz"; then
        if [[ "$url" != "${base}.tar.gz" ]]; then
            url="${base}.tar.gz"
            log "改下 $url"
            curl -fsSL --max-time 300 "$url" -o "$WORK/sing-box.tar.gz" || { err "sing-box 下载失败"; exit 1; }
        else
            err "sing-box 下载失败"
            exit 1
        fi
    fi
    mkdir -p "$WORK/sb"
    tar -xzf "$WORK/sing-box.tar.gz" -C "$WORK/sb"
    local bin
    bin=$(find "$WORK/sb" -type f -name sing-box | head -n1)
    if [[ -z "$bin" ]]; then
        err "压缩包里没有 sing-box 可执行文件"
        exit 1
    fi
    install -d -m 0755 /usr/local/bin
    install -m 0755 "$bin" /usr/local/bin/sing-box
    if ! /usr/local/bin/sing-box version >/dev/null 2>&1; then
        err "下载的 sing-box 在本机跑不起来(libc 不匹配?)"
        exit 1
    fi
}

install_singbox_apt() {
    export DEBIAN_FRONTEND=noninteractive
    if [[ ! -f /etc/apt/keyrings/sagernet.asc ]]; then
        log "添加 sing-box apt 源"
        install -d -m 0755 /etc/apt/keyrings
        curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc || return 1
        chmod a+r /etc/apt/keyrings/sagernet.asc
        echo "deb [signed-by=/etc/apt/keyrings/sagernet.asc] https://deb.sagernet.org/ * *" \
            > /etc/apt/sources.list.d/sagernet.list
    fi
    apt-get update -y >&2 && apt-get install -y sing-box >&2
}

install_singbox_dnf() {
    local pm=yum
    command -v dnf >/dev/null 2>&1 && pm=dnf
    if [[ ! -f /etc/yum.repos.d/sing-box.repo ]]; then
        log "添加 sing-box yum/dnf 源"
        curl -fsSL https://sing-box.app/sing-box.repo -o /etc/yum.repos.d/sing-box.repo || return 1
    fi
    "$pm" install -y sing-box >&2
}

install_singbox() {
    if command -v sing-box >/dev/null 2>&1; then
        log "sing-box 已安装: $(sing-box version 2>/dev/null | head -n1)"
        return 0
    fi
    case "$DISTRO" in
        debian)
            install_singbox_apt || {
                log "apt 安装 sing-box 失败,改用 GitHub release"
                dpkg --remove --force-remove-reinstreq sing-box >/dev/null 2>&1 || true
                rm -f /etc/apt/sources.list.d/sagernet.list
                install_singbox_tarball
            } ;;
        rhel)
            install_singbox_dnf || {
                log "dnf/yum 安装 sing-box 失败,改用 GitHub release"
                rm -f /etc/yum.repos.d/sing-box.repo
                install_singbox_tarball
            } ;;
        *) install_singbox_tarball ;;
    esac
    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 安装后仍找不到"
        exit 1
    fi
    log "sing-box: $(sing-box version 2>/dev/null | head -n1)"
}

install_singbox
SB_BIN=$(command -v sing-box)


detect_ips() {
    ip -4 -o addr show scope global 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 | sort -u \
        | awk '
            /^10\./                            { next }
            /^172\.(1[6-9]|2[0-9]|3[01])\./    { next }
            /^192\.168\./                      { next }
            /^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\./ { next }
            /^169\.254\./                      { next }
            /^127\./                           { next }
            { print }
        '
}

public_ip() {
    local u v
    for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
        v=$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d ' \r\n') || continue
        if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$v"
            return 0
        fi
    done
    return 1
}

SINGLE=0
SHOW_IP=""
if [[ ${#IPS[@]} -eq 0 ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] && IPS+=("$line")
    done < <(detect_ips)
fi
if [[ ${#IPS[@]} -eq 0 ]]; then
    SINGLE=1
    log "网卡上没有公网 IPv4(NAT 云),改为单出口模式:监听 0.0.0.0、直连出站"
    if SHOW_IP=$(public_ip); then
        log "公网出口 IP: $SHOW_IP"
    else
        SHOW_IP="<PUBLIC_IP>"
        log "查不到公网 IP,输出里用 <PUBLIC_IP> 占位,请自行替换"
    fi
else
    log "绑定 IP: ${IPS[*]}"
fi


ip_to_suffix() { echo "$1" | tr '.' '_'; }
random_password() { openssl rand -base64 18 | tr -d '=+/\n' | head -c 20; }
json_escape() {
    local s=${1//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

declare -a USERS=() PASSWORDS=() SHOWS=()
if [[ $SINGLE -eq 1 ]]; then
    if [[ "$SHOW_IP" = "<PUBLIC_IP>" ]]; then
        USERS+=("${USER_PREFIX}_egress")
    else
        USERS+=("${USER_PREFIX}_$(ip_to_suffix "$SHOW_IP")")
    fi
    PASSWORDS+=("$(random_password)")
    SHOWS+=("$SHOW_IP")
else
    for ip in "${IPS[@]}"; do
        USERS+=("${USER_PREFIX}_$(ip_to_suffix "$ip")")
        PASSWORDS+=("$(random_password)")
        SHOWS+=("$ip")
    done
fi

write_singbox_conf() {
    local conf=/etc/sing-box/config.json
    log "写入 $conf"
    install -d -m 0755 /etc/sing-box

    local users_json="" i
    for i in "${!USERS[@]}"; do
        [[ $i -gt 0 ]] && users_json+=','
        users_json+="{\"username\":\"$(json_escape "${USERS[$i]}")\",\"password\":\"$(json_escape "${PASSWORDS[$i]}")\"}"
    done

    local inbounds_json="" outbounds_json="" rules_json="" final_tag=""
    if [[ $SINGLE -eq 1 ]]; then
        inbounds_json="{\"type\":\"socks\",\"tag\":\"in-all\",\"listen\":\"0.0.0.0\",\"listen_port\":$SOCKS_PORT,\"users\":[$users_json]}"
        outbounds_json="{\"type\":\"direct\",\"tag\":\"direct\"}"
        final_tag="direct"
    else
        for i in "${!IPS[@]}"; do
            local ip="${IPS[$i]}" suffix in_tag out_tag
            suffix=$(ip_to_suffix "$ip")
            in_tag="in-$suffix"
            out_tag="out-$suffix"
            [[ -z "$final_tag" ]] && final_tag="$out_tag"
            if [[ $i -gt 0 ]]; then
                inbounds_json+=','
                outbounds_json+=','
                rules_json+=','
            fi
            inbounds_json+="{\"type\":\"socks\",\"tag\":\"$in_tag\",\"listen\":\"$ip\",\"listen_port\":$SOCKS_PORT,\"users\":[$users_json]}"
            outbounds_json+="{\"type\":\"direct\",\"tag\":\"$out_tag\",\"inet4_bind_address\":\"$ip\"}"
            rules_json+="{\"inbound\":[\"$in_tag\"],\"outbound\":\"$out_tag\"}"
        done
    fi

    cat > "$conf" <<CONF_END
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [$inbounds_json],
  "outbounds": [$outbounds_json],
  "route": {
    "rules": [$rules_json],
    "final": "$final_tag"
  }
}
CONF_END
    chmod 0600 "$conf"

    if ! "$SB_BIN" check -C /etc/sing-box >"$WORK/check.out" 2>&1; then
        err "sing-box check 失败:"
        cat "$WORK/check.out" >&2 || true
        exit 1
    fi
    log "sing-box check 通过"
}

write_singbox_conf


start_nohup() {
    if command -v pkill >/dev/null 2>&1; then
        pkill -f "sing-box run -C /etc/sing-box" 2>/dev/null || true
        sleep 0.5
    fi
    nohup "$SB_BIN" run -C /etc/sing-box >/var/log/sing-box.log 2>&1 &
    log "已用 nohup 在后台启动 sing-box(pid $!,日志 /var/log/sing-box.log;重启机器后不会自启)"
}

start_service() {
    if [[ $NO_START -eq 1 ]]; then
        log "不启动服务(--no-start)"
        return 0
    fi
    if [[ "$(cat /proc/1/comm 2>/dev/null)" = systemd ]]; then
        if [[ ! -f /lib/systemd/system/sing-box.service && ! -f /usr/lib/systemd/system/sing-box.service ]]; then
            log "写入 /etc/systemd/system/sing-box.service"
            cat > /etc/systemd/system/sing-box.service <<UNIT_END
[Unit]
Description=sing-box
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$SB_BIN run -C /etc/sing-box
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
UNIT_END
        fi
        systemctl daemon-reload
        systemctl enable sing-box >&2 2>/dev/null || true
        systemctl restart sing-box
        log "systemd: sing-box 已启动"
        return 0
    fi
    if command -v rc-service >/dev/null 2>&1; then
        log "写入 /etc/init.d/sing-box(OpenRC)"
        cat > /etc/init.d/sing-box <<OPENRC_END
#!/sbin/openrc-run
name="sing-box"
command="$SB_BIN"
command_args="run -C /etc/sing-box"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"

depend() {
    need net
}
OPENRC_END
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default >/dev/null 2>&1 || true
        if rc-service sing-box restart >&2 2>&1 || rc-service sing-box start >&2 2>&1; then
            log "OpenRC: sing-box 已启动"
            return 0
        fi
        log "rc-service 启动失败(OpenRC 可能没在运行),改用 nohup"
        start_nohup
        return 0
    fi
    log "警告: 既不是 systemd 也没有 OpenRC(容器 / 其它 init),不装开机自启"
    start_nohup
}

start_service


port_listening() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk -v p=":$SOCKS_PORT" '$4 ~ p"$" {f=1} END {exit !f}' && return 0
    fi
    local hex
    hex=$(printf '%04X' "$SOCKS_PORT")
    awk -v h=":$hex" '$4 == "0A" && $2 ~ h"$" {f=1} END {exit !f}' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

if [[ $NO_START -eq 0 ]]; then
    ok=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if port_listening; then ok=1; break; fi
        sleep 0.5
    done
    if [[ $ok -eq 1 ]]; then
        log "端口 $SOCKS_PORT 已在监听"
    else
        err "5 秒内端口 $SOCKS_PORT 没有进入监听,查看 sing-box 日志"
        exit 1
    fi
fi

log "出口探测: $(probe_verdict)"
log "代理地址:"
for i in "${!USERS[@]}"; do
    printf 'socks5://%s:%s@%s:%s\n' "${USERS[$i]}" "${PASSWORDS[$i]}" "${SHOWS[$i]}" "$SOCKS_PORT"
done
exit 0
WATERSOCKS_BODY_END
WATERSOCKS_SELF_TMP=1 exec bash "$WATERSOCKS_SELF" "$@" </dev/null
