#!/bin/bash
# Local DICOMweb nodes for cross-testing two clients against each other.
#
#   serve-dicomweb-interop.sh start|stop|status RUNTIME_DIR
#
# RUNTIME_DIR holds everything this creates (credentials, certificate, Orthanc
# database, dicomtool storage, logs) and must be outside Git. It needs:
#   RUNTIME_DIR/orthanc-bin  the unpacked official Orthanc macOS package
#                            (Orthanc and libOrthancDicomWeb.dylib), or ORTHANC_DIR
#   DICOMTOOL                dicomtool from DICOM-Swift; defaults to the release
#                            build of a DICOM-Swift checkout next to this repository
# and caddy and openssl on PATH.
#
# Nodes, all on loopback (the base URL is followed by /dicom-web):
#   8042  Orthanc, HTTP, its own Basic authentication
#   8041  Orthanc through Caddy, HTTP, no authentication (Caddy adds the Basic pair)
#   8044  Orthanc through Caddy, HTTP, Bearer token; missing or wrong token is 401
#   8443  Orthanc through Caddy, HTTPS with a self-signed certificate, Basic
#   8051  dicomtool, HTTP, no authentication
#   8052  dicomtool, HTTP, Basic
#   8053  dicomtool, HTTP, Bearer
#   8454  dicomtool, HTTPS with the same self-signed certificate, Basic
# The Basic pair and the Bearer token are generated once into
# RUNTIME_DIR/credentials.env (mode 600); the certificate is RUNTIME_DIR/tls/cert.pem.
set -euo pipefail

action=${1:-}; runtime=${2:-}
if [[ -z $action || -z $runtime ]]; then
    echo "usage: $0 start|stop|status RUNTIME_DIR" >&2; exit 64
fi
repo=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$runtime"; runtime=$(cd "$runtime" && pwd)
case $runtime/ in "$repo"/*) echo "RUNTIME_DIR must be outside the repository" >&2; exit 64;; esac
orthanc_dir=${ORTHANC_DIR:-$runtime/orthanc-bin}
dicomtool=${DICOMTOOL:-$repo/../DICOM-Swift/.build/release/dicomtool}
run=$runtime/run; logs=$runtime/logs
mkdir -p "$run" "$logs"

ports=(8042 8041 8044 8443 8051 8052 8053 8454)

stop_all() {
    for pidfile in "$run"/*.pid; do
        [[ -e $pidfile ]] || continue
        pid=$(cat "$pidfile")
        kill "$pid" 2>/dev/null || true
        for _ in {1..50}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        kill -9 "$pid" 2>/dev/null || true
        rm -f "$pidfile"
    done
}

status_all() {
    local failed=0
    for port in "${ports[@]}"; do
        if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then echo "$port listening"
        else echo "$port down"; failed=1; fi
    done
    return $failed
}

case $action in
    stop) stop_all; exit 0;;
    status) status_all; exit $?;;
    start) ;;
    *) echo "unknown action $action" >&2; exit 64;;
esac

[[ -x $orthanc_dir/Orthanc && -e $orthanc_dir/libOrthancDicomWeb.dylib ]] \
    || { echo "Orthanc package not found in $orthanc_dir" >&2; exit 2; }
[[ -x $dicomtool ]] || { echo "dicomtool not found at $dicomtool" >&2; exit 2; }
command -v caddy >/dev/null && command -v openssl >/dev/null \
    || { echo "caddy and openssl are required" >&2; exit 2; }
for port in "${ports[@]}"; do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "port $port is already in use; run stop first" >&2; exit 1
    fi
done

credentials=$runtime/credentials.env
if [[ ! -e $credentials ]]; then
    umask 077
    printf 'INTEROP_USER=interop\nINTEROP_PASSWORD=%s\nINTEROP_TOKEN=%s\n' \
        "$(openssl rand -hex 12)" "$(openssl rand -hex 24)" > "$credentials"
    umask 022
fi
# shellcheck source=/dev/null
source "$credentials"
basic_header="Basic $(printf '%s:%s' "$INTEROP_USER" "$INTEROP_PASSWORD" | base64)"

tls=$runtime/tls
if [[ ! -e $tls/cert.pem ]]; then
    mkdir -p "$tls"
    openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
        -keyout "$tls/key.pem" -out "$tls/cert.pem" -subj "/CN=localhost" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "extendedKeyUsage=serverAuth" 2>/dev/null
    chmod 600 "$tls/key.pem"
fi

mkdir -p "$runtime/orthanc/db"
cat > "$runtime/orthanc/config.json" <<EOF
{
  "Name": "INTEROP",
  "StorageDirectory": "$runtime/orthanc/db",
  "IndexDirectory": "$runtime/orthanc/db",
  "Plugins": [ "$orthanc_dir/libOrthancDicomWeb.dylib" ],
  "HttpPort": 8042,
  "RemoteAccessAllowed": false,
  "AuthenticationEnabled": true,
  "RegisteredUsers": { "$INTEROP_USER": "$INTEROP_PASSWORD" },
  "DicomServerEnabled": false,
  "DicomWeb": {
    "Enable": true,
    "Root": "/dicom-web/",
    "EnableWado": true,
    "WadoRoot": "/wado",
    "StudiesMetadata": "Full",
    "SeriesMetadata": "Full"
  }
}
EOF

cat > "$runtime/Caddyfile" <<EOF
{
	admin off
	auto_https off
	storage file_system $runtime/caddy
}

http://127.0.0.1:8041, http://localhost:8041 {
	reverse_proxy 127.0.0.1:8042 {
		header_up Authorization "$basic_header"
	}
}

http://127.0.0.1:8044, http://localhost:8044 {
	@token header Authorization "Bearer $INTEROP_TOKEN"
	handle @token {
		reverse_proxy 127.0.0.1:8042 {
			header_up Authorization "$basic_header"
		}
	}
	handle {
		header WWW-Authenticate "Bearer realm=\"interop\""
		respond 401
	}
}

https://127.0.0.1:8443, https://localhost:8443 {
	tls $tls/cert.pem $tls/key.pem
	reverse_proxy 127.0.0.1:8042 {
		header_up Forwarded "proto=https;host={host}"
	}
}
EOF
chmod 600 "$runtime/Caddyfile" "$runtime/orthanc/config.json"

launch() { # name, command...
    local name=$1; shift
    nohup "$@" > "$logs/$name.log" 2>&1 &
    echo $! > "$run/$name.pid"
}

trap 'stop_all' ERR
launch orthanc "$orthanc_dir/Orthanc" "$runtime/orthanc/config.json"
launch caddy caddy run --config "$runtime/Caddyfile" --adapter caddyfile
for node in open basic bearer tls; do mkdir -p "$runtime/dicomtool/$node"; done
launch dicomtool-open "$dicomtool" web serve "$runtime/dicomtool/open" --port 8051
launch dicomtool-basic "$dicomtool" web serve "$runtime/dicomtool/basic" --port 8052 \
    --basic "$INTEROP_USER:$INTEROP_PASSWORD"
launch dicomtool-bearer "$dicomtool" web serve "$runtime/dicomtool/bearer" --port 8053 \
    --bearer "$INTEROP_TOKEN"
launch dicomtool-tls "$dicomtool" web serve "$runtime/dicomtool/tls" --port 8454 \
    --basic "$INTEROP_USER:$INTEROP_PASSWORD" \
    --tls-certificate "$tls/cert.pem" --tls-key "$tls/key.pem"

for _ in {1..100}; do status_all >/dev/null && break; sleep 0.2; done
trap - ERR
if ! status_all; then
    echo "some nodes did not start; logs are in $logs" >&2
    stop_all; exit 1
fi
echo "credentials: $credentials"
echo "certificate: $tls/cert.pem"
