#!/usr/bin/env bash
#
# install-mediathek-backend.sh
#
# Baut und installiert ohne Docker aus
#   https://github.com/neutrino-images/ni-neutrino-mediathek-backend
#   - mediathek-db-import/ (mv2mariadb)  -> /opt/mediathek/importer
#   - mediathek-api-dev/   (mt-api)      -> /opt/mediathek/api
# für den Betrieb auf einem öffentlichen Server hinter Apache (HTTPS):
#
#   Internet (https)
#      |
#      v
#   Apache (mt-api.neutrino-images.de bzw. /mt-api/... der Hauptseite)
#      |
#      v
#   lighttpd (127.0.0.1:18080)
#      |
#      v
#   mt-api (CGI)
#      |
#      v
#    liest
#       \
#        MariaDB (mediathek_1)
#       /
#    schreibt
#      ^
#      |
#   mv2mariadb (stündlich per systemd-Timer)
#
# Nach jedem Import schreibt mediathek-webtv.service die Livestreams als
# WebTV-Liste für Neutrino, die Apache als statische Datei ausliefert:
#   https://mt-api.neutrino-images.de/livestreams.xml
# Die EPG dazu holt die Box selbst aus dem XMLTV-Guide von epgshare01.
#
# Stündlich schreibt mediathek-stats.timer aus dem Apache-Zugriffslog eine
# statische Statistikseite: https://mt-api.neutrino-images.de/
#
# Ziel: Debian 12/13, Ubuntu 22.04/24.04. Als root ausführen.
# Aufruf:
#   install-mediathek-backend.sh              installieren bzw. aktualisieren
#   install-mediathek-backend.sh --check      zeigen, ob es upstream Neues gibt
#   install-mediathek-backend.sh --verify     prüfen, ob installierte Dateien
#                                             verändert wurden (Rückgabe 1)
#   install-mediathek-backend.sh --rollback   zur vorherigen Version zurück
#                                             (nochmal aufrufen = wieder vor)
#
# Mehrfach ausführbar: Ein erneuter Lauf holt den aktuellen Git-Stand, baut neu
# und tauscht die Programme aus. Konfiguration und Passwörter bleiben erhalten.
# Vor dem Austausch wird die laufende Version gesichert (eine Generation, unter
# /var/lib/mediathek-backend/prev). Schlägt der Build fehl, bleibt die alte
# Version unverändert in Betrieb.
#
# Der vorhandene Apache-VirtualHost wird NICHT verändert. Das Skript legt
# /etc/apache2/mediathek-api.inc an; diese Datei bindest du selbst in den
# HTTPS-VirtualHost ein (siehe Ausgabe am Ende).
#
# Anpassbar über Umgebungsvariablen:
#   API_PORT=18080        interner Port von lighttpd (nur 127.0.0.1)
#   DB_HOST=localhost     MariaDB-Server. Bei "localhost" wird MariaDB lokal
#                         installiert und die Benutzer werden angelegt.
#                         Bei einem anderen Host musst du die Benutzer selbst
#                         anlegen und IMPORT_PW / API_PW mitgeben.
#   IMPORT_USER=mt_import / IMPORT_PW=...   DB-Benutzer des Importers
#   API_USER=mt_api       / API_PW=...      DB-Benutzer der API (nur lesend)
#   APACHE=1              Apache-Anbindung vorbereiten (0 = weglassen)
#   API_DOMAIN=mt-api.neutrino-images.de
#                         eigene Subdomain für die API (leer = keine; dann nur
#                         /mt-api im vHost der Hauptseite)
#   QOS=1                 Begrenzung mit mod_qos einrichten (0 = weglassen)
#   QOS_PER_IP=300        max. API-Anfragen pro IP und Minute (mod_qos)
#   QOS_CONCURRENT=30     max. gleichzeitige API-Anfragen insgesamt (mod_qos)
#   EPG_XMLTV=<URL>       XMLTV-Guide, den die WebTV-Liste den Boxen für die
#                         EPG der Livestreams nennt (Standard: Deutschland-
#                         Datei von epgshare01; leer = Liste ohne EPG)
#   SKIP_FIRST_IMPORT=1   ersten Vollimport nicht automatisch starten
#   FORCE=1               auch installieren, wenn installierte Dateien seit dem
#                         letzten Lauf verändert wurden (siehe --verify)
#   REF=<tag|commit>      bestimmten Stand des Repos bauen, z. B. REF=NI-2026.11
#                         Ohne Angabe: Wird das Skript aus einem Checkout des
#                         Repos gestartet, wird genau dessen Commit gebaut,
#                         sonst der aktuelle Stand des Standard-Branches.
#
set -euo pipefail

# Schutz gegen Überschreiben während des Laufs: Bash liest Skripte stückweise.
# Ändert sich diese Datei mitten im Lauf (z. B. durch git checkout oder git pull
# im Repo, aus dem sie stammt), liefe ein Gemisch aus alter und neuer Version.
# Deshalb startet das Skript sich als Erstes aus einer privaten Kopie neu.
if [ -z "${MT_INSTALLER_SELF:-}" ]; then
  MT_INSTALLER_SELF="$(readlink -f "$0")"
  MT_INSTALLER_COPY="$(mktemp "${TMPDIR:-/tmp}/install-mediathek-backend.XXXXXX")"
  cp "$MT_INSTALLER_SELF" "$MT_INSTALLER_COPY"
  export MT_INSTALLER_SELF MT_INSTALLER_COPY
  exec bash "$MT_INSTALLER_COPY" "$@"
fi
SELF="$MT_INSTALLER_SELF"          # Pfad der Originaldatei (für Hinweise)
export -n MT_INSTALLER_SELF MT_INSTALLER_COPY
trap 'rm -f "${MT_INSTALLER_COPY:-}"' EXIT

API_PORT="${API_PORT:-18080}"
DB_HOST="${DB_HOST:-localhost}"
IMPORT_USER="${IMPORT_USER:-mt_import}"
API_USER="${API_USER:-mt_api}"
APACHE="${APACHE:-1}"
API_DOMAIN="${API_DOMAIN-mt-api.neutrino-images.de}"
ACME_ROOT="/var/www/mediathek-api"   # Document-Root der Subdomain (leer, Let's-Encrypt-Prüfdateien)
WEBTV_DIR="/var/lib/mediathek-webtv" # WebTV-Liste der Livestreams (StateDirectory der Unit)
STATS_DIR="/var/lib/mediathek-stats" # Statistikseite und ihre Tagessummen (StateDirectory)
API_LOG="/var/log/apache2/mediathek-api-access.log" # Zugriffe auf die API über Apache
EPG_XMLTV="${EPG_XMLTV-https://epgshare01.online/epgshare01/epg_ripper_DE1.xml.gz}"
QOS="${QOS:-1}"
QOS_PER_IP="${QOS_PER_IP:-300}"
QOS_CONCURRENT="${QOS_CONCURRENT:-30}"
SRC_DIR="${SRC_DIR:-/usr/local/src/mediathek}"
SVC_USER="mediathek"       # Importer und Build
WEB_USER="mt-api"          # lighttpd + mt-api (nicht www-data, das gehört Apache)
MT_BASE="/opt/mediathek"
IMPORTER_HOME="$MT_BASE/importer"
IMPORTER_DIR="$IMPORTER_HOME/bin"
API_HOME="$MT_BASE/api"
REPO_URL="https://github.com/neutrino-images/ni-neutrino-mediathek-backend.git"
REPO_DIR="$SRC_DIR/ni-neutrino-mediathek-backend"
IMPORT_SRC="$REPO_DIR/mediathek-db-import"
API_SRC="$REPO_DIR/mediathek-api-dev"
STATE_DIR="/var/lib/mediathek-backend"
BACKUP_DIR="$STATE_DIR/prev"
VERSION_FILE="$STATE_DIR/installed.version"
# Konfigurationsdateien, Units und Hilfsskripte liegen im Repo unter system/,
# mit dem Zielpfad als Pfad darunter (system/etc/... -> /etc/...). Platzhalter
# @NAME@ darin werden durch die gleichnamige Variable ersetzt. Die Prüfsummen
# der installierten Dateien stehen in $MANIFEST: Ein Lauf bricht ab, wenn eine
# davon seitdem verändert wurde (FORCE=1 überschreibt trotzdem).
SYSTEM_DIR="$REPO_DIR/system"
MANIFEST="$STATE_DIR/installed.sha256"
LE_DIR="/etc/letsencrypt/live/$API_DOMAIN"
# Neuere GCC-Versionen melden Warnungen, die das Makefile per -Werror zu
# Fehlern macht. Diese werden hier (wie im offiziellen Dockerfile) entschärft.
RELAX="-Wno-error=deprecated-declarations -Wno-error=unused-value -Wno-error=unused-result -Wno-error=stringop-truncation -Wno-error=ignored-qualifiers"
TEMPLATE_VARS=(API_PORT API_HOME IMPORTER_DIR WEB_USER SVC_USER DB_HOST WEBTV_DIR
               STATS_DIR API_LOG EPG_XMLTV API_DOMAIN ACME_ROOT LE_DIR
               QOS_CONCURRENT QOS_PER_IP SRC_DIR RELAX)
# Alles, was ein Update austauscht und ein Rollback zurückholt.
# Nicht dabei (bleibt immer erhalten): Passwörter, mv2mariadb.conf, Datenbank, Logs.
MANAGED_PATHS=(
  "$IMPORTER_DIR/mv2mariadb"
  "$IMPORTER_DIR/sql"
  "$API_HOME/bin/mt-api"
  "$API_HOME/bin/mediathek-webtv-xml"
  "$API_HOME/data/livestreams-epg.tsv"
  "$API_HOME/bin/mediathek-stats"
  "$API_HOME/www"
  "$API_HOME/data/template"
  /etc/mediathek-api/lighttpd.conf
  /etc/systemd/system/mediathek-api.service
  /etc/systemd/system/mediathek-importer.service
  /etc/systemd/system/mediathek-importer.timer
  /etc/systemd/system/mediathek-importer-full.service
  /etc/systemd/system/mediathek-webtv.service
  /etc/systemd/system/mediathek-stats.service
  /etc/systemd/system/mediathek-stats.timer
  /etc/logrotate.d/mediathek-api
  /etc/apache2/mediathek-api.inc
  /etc/apache2/sites-available/mediathek-api.conf
  /etc/apache2/conf-available/mediathek-api-qos.conf
  "$VERSION_FILE"
  "$MANIFEST"
)

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Bitte als root ausführen (sudo $SELF)."
command -v apt-get >/dev/null || die "Nur für Debian/Ubuntu (apt) gedacht."

HAVE_SYSTEMD=0
[ -d /run/systemd/system ] && HAVE_SYSTEMD=1

is_local_db() { case "$DB_HOST" in localhost|127.0.0.1|::1) return 0;; *) return 1;; esac; }
randpw() { openssl rand -hex 16; }
# Passwort aus "user:pass"-Datei lesen (falls vorhanden)
pw_from_file() { [ -f "$1" ] && cut -d: -f2- "$1" || true; }
as_svc() { runuser -u "$SVC_USER" -- env HOME="$SRC_DIR" "$@"; }

# mod_qos installieren. Debian 12: Das Paket aus bookworm (11.63) lässt sich mit
# dem aktuellen Apache nicht laden ("undefined symbol: pcre_free"); die
# korrigierte Version gibt es in bookworm-backports. Rückgabe 1 = nicht möglich.
install_mod_qos() {
  local codename=""
  [ -r /etc/os-release ] && codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  if [ "$codename" = bookworm ]; then
    if apt-cache policy libapache2-mod-qos | grep -q 'bookworm-backports'; then
      apt-get install -y -qq --no-install-recommends -t bookworm-backports libapache2-mod-qos >/dev/null
    else
      warn "Debian 12: libapache2-mod-qos aus bookworm ist defekt, die funktionierende Version liegt in bookworm-backports – die sind hier nicht eingerichtet."
      return 1
    fi
  else
    apt-get install -y -qq --no-install-recommends libapache2-mod-qos >/dev/null
  fi
}

# Version eines Repo-Stands aus dem letzten NI-Tag; $1 = Commit (Standard: HEAD)
build_version() {
  local v
  v="$(as_svc git -C "$REPO_DIR" describe --tags --match 'NI-*' "${1:-HEAD}" 2>/dev/null)" \
    || die "Kein NI-Tag vor Commit $(as_svc git -C "$REPO_DIR" rev-parse --short "${1:-HEAD}") gefunden – Stände vor NI-2026.11 werden nicht unterstützt."
  echo "${v#NI-}"
}

# Werte landen in SQL-Befehlen und Passwortdateien: nur harmlose Zeichen zulassen
check_credentials() {
  case "$API_DOMAIN" in *[!a-z0-9.-]*) die "API_DOMAIN darf nur Kleinbuchstaben, Ziffern, Punkt und Bindestrich enthalten.";; esac
  local v
  for v in "$IMPORT_USER" "$API_USER" "$IMPORT_PW" "$API_PW"; do
    case "$v" in ''|*[!A-Za-z0-9._-]*) die "Benutzernamen und Passwörter dürfen nur A-Z, a-z, 0-9, Punkt, Unterstrich und Bindestrich enthalten.";; esac
  done
}


# Vollimport im Hintergrund starten (überlebt einen SSH-Abbruch). Läuft über
# die gehärtete Unit mediathek-importer-full.service, nicht als freier Prozess.
start_full_import() {
  [ "$HAVE_SYSTEMD" = 1 ] || { warn "systemd fehlt – Vollimport bitte von Hand: cd $IMPORTER_DIR && sudo -u $SVC_USER ./mv2mariadb --force-convert"; return 0; }
  log "Vollimport im Hintergrund starten ($1)"
  systemctl reset-failed mediathek-importer-full.service 2>/dev/null || true
  systemctl start --no-block mediathek-importer-full.service
  echo "    Fortschritt: journalctl -fu mediathek-importer-full"
}

# Datei oder Verzeichnis $1 samt Pfad unter $2 ablegen (/a/b -> $2/a/b).
# Bewusst nicht "cp --parents": In coreutils 9.1 bis 9.3 (Debian 12) schlägt
# "cp -a --parents" mit absoluten Pfaden fehl ("No such file or directory").
copy_with_path() {
  local dst
  dst="$2$(dirname "$1")"
  mkdir -p "$dst"
  cp -a "$1" "$dst/"
}

# Vorlage $1 aus system/ mit eingesetzten Werten auf stdout ausgeben
render() {
  local t v
  t="$(cat "$1"; printf x)"; t="${t%x}"
  for v in "${TEMPLATE_VARS[@]}"; do
    t="${t//@$v@/"${!v}"}"      # in Anführungszeichen: & bleibt & (bash 5.2)
  done
  if printf '%s' "$t" | grep -q '@[A-Z][A-Z_]*@'; then
    die "Unbekannter Platzhalter in $1: $(printf '%s' "$t" | grep -o '@[A-Z][A-Z_]*@' | sort -u | tr '\n' ' ')"
  fi
  printf '%s' "$t"
}

# Prüfsumme der installierten Datei $1 in $MANIFEST eintragen bzw. erneuern
manifest_set() {
  local tmp
  install -d -m 755 "$STATE_DIR"
  tmp="$(mktemp "$MANIFEST.XXXXXX")"
  { [ -f "$MANIFEST" ] && awk -v p="$1" '$2 != p' "$MANIFEST"; sha256sum "$1"; } > "$tmp"
  chmod 644 "$tmp"
  mv "$tmp" "$MANIFEST"
}

# Datei aus system/ an ihren Zielpfad installieren: put_file /etc/...
put_file() {
  local src="$SYSTEM_DIR$1" mode=644
  [ -f "$src" ] || die "$src fehlt im Repo."
  case "$1" in */bin/*) mode=755 ;; esac
  mkdir -p "$(dirname "$1")"
  render "$src" > "$1.new"
  chmod "$mode" "$1.new"
  mv "$1.new" "$1"
  manifest_set "$1"
}

# Installierte Dateien, die nicht mehr zu ihrer Prüfsumme passen (oder fehlen)
changed_system_files() {
  [ -f "$MANIFEST" ] || return 0
  sha256sum --quiet -c "$MANIFEST" 2>/dev/null | sed 's/: [^:]*$//' || true
}

# Vor dem Überschreiben: Hat jemand installierte Dateien verändert?
# $1 = Option des Laufs (für den Hinweis), z. B. --rollback
guard_system_files() {
  local changed
  changed="$(changed_system_files)"
  [ -n "$changed" ] || return 0
  warn "Diese Dateien wurden seit der Installation verändert oder gelöscht:"
  printf '    %s\n' $changed >&2
  if [ "${FORCE:-0}" = 1 ]; then
    warn "FORCE=1: Sie werden mit dem Stand aus dem Repo überschrieben."
    return 0
  fi
  die "Abbruch, es wurde nichts geändert. Gewollte Änderungen gehören ins Repo (system/); überschreiben mit: sudo FORCE=1 $SELF${1:+ $1}"
}

# Laufende Version nach $BACKUP_DIR sichern (ersetzt die vorige Sicherung)
backup_installed() {
  rm -rf "$BACKUP_DIR.new"
  install -d -m 700 "$BACKUP_DIR.new"
  local p
  for p in "${MANAGED_PATHS[@]}"; do
    [ -e "$p" ] && copy_with_path "$p" "$BACKUP_DIR.new"
  done
  rm -rf "$BACKUP_DIR"
  mv "$BACKUP_DIR.new" "$BACKUP_DIR"
}

importer_running() {
  [ "$HAVE_SYSTEMD" = 1 ] && { systemctl is-active -q mediathek-importer.service || systemctl is-active -q mediathek-importer-full.service; }
}

apache_files_differ() {  # $1 = Vergleichsverzeichnis (Sicherung)
  local f
  for f in /etc/apache2/mediathek-api.inc /etc/apache2/sites-available/mediathek-api.conf /etc/apache2/conf-available/mediathek-api-qos.conf; do
    [ -e "$1$f" ] || [ -e "$f" ] || continue
    cmp -s "$1$f" "$f" || return 0
  done
  return 1
}

# Ergebnis der Prüfsummen ausgeben; Rückgabe 1, wenn etwas verändert ist
report_system_files() {
  local changed
  if [ ! -f "$MANIFEST" ]; then
    echo "Systemdateien: keine Prüfsummen vorhanden (noch nicht oder vor ihrer Einführung installiert)"
    return 0
  fi
  changed="$(changed_system_files)"
  if [ -z "$changed" ]; then
    echo "Systemdateien: unverändert ($(wc -l < "$MANIFEST") Dateien geprüft)"
    return 0
  fi
  echo "Systemdateien: VERÄNDERT oder gelöscht:"
  printf '   %s\n' $changed
  return 1
}

do_check() {
  # Installierte Version und Zusatzangaben (repo=…, script=…) getrennt
  local inst_ver="noch nicht installiert" inst_rest=""
  if [ -f "$VERSION_FILE" ]; then
    inst_ver="$(sed -n 's/.*version=\([^ ]*\).*/\1/p' "$VERSION_FILE")"
    inst_rest="$(sed 's/version=[^ ]* *//; s/ /, /g' "$VERSION_FILE")"
  fi
  report_system_files || true
  if [ ! -d "$REPO_DIR/.git" ]; then
    printf '%-13s %s\n' "Installiert:" "$inst_ver${inst_rest:+  ($inst_rest)}"
    echo "Repo noch nicht geklont ($REPO_DIR)"; return 0
  fi
  as_svc git -C "$REPO_DIR" fetch -q --tags origin
  local latest_tag repo_ver w
  latest_tag="$(as_svc git -C "$REPO_DIR" describe --tags --match 'NI-*' --abbrev=0 origin/HEAD 2>/dev/null || true)"
  repo_ver="$(build_version origin/HEAD)"
  # Versionen untereinander, Zusatzangaben in einer gemeinsamen Spalte dahinter
  w=${#inst_ver}; [ ${#repo_ver} -gt "$w" ] && w=${#repo_ver}
  { printf '%-13s %-*s  %s\n' "Installiert:" "$w" "$inst_ver" "${inst_rest:+($inst_rest)}"
    printf '%-13s %-*s  %s\n' "Im Repo:" "$w" "$repo_ver" "(neuester Stand${latest_tag:+, letzte Freigabe $latest_tag})"
  } | sed 's/ *$//'
  # Vergleichsbasis ist der installierte Commit aus der Versionsdatei, nicht der
  # Quellbaum (der kann nach einem abgebrochenen Lauf auf einem anderen Stand sein).
  local base
  base="$(sed -n 's/.*repo=\([0-9a-f]*\).*/\1/p' "$VERSION_FILE" 2>/dev/null || true)"
  [ -n "$base" ] || { echo "Noch nichts installiert – Vergleich entfällt."; return 0; }
  echo "== neu seit dem installierten Stand ($base):"
  local new_commits
  new_commits="$(as_svc git -C "$REPO_DIR" log --oneline --decorate=short "$base..origin/HEAD")"
  if [ -n "$new_commits" ]; then
    printf '%s\n' "$new_commits" | sed 's/^/   /'
  else
    echo "   nichts Neues"
  fi
  local dd="mediathek-db-import/docker mediathek-api-dev/docker"
  # shellcheck disable=SC2086
  if ! as_svc git -C "$REPO_DIR" diff --quiet "$base" origin/HEAD -- $dd; then
    echo "   Achtung: docker/ hat sich geändert – prüfen, ob das Skript angepasst werden muss:"
    # shellcheck disable=SC2086
    as_svc git -C "$REPO_DIR" diff --stat "$base" origin/HEAD -- $dd | sed 's/^/     /'
  fi
}

do_rollback() {
  [ -f "$BACKUP_DIR$VERSION_FILE" ] || die "Keine Sicherung vorhanden ($BACKUP_DIR). Ein Rollback ist erst nach einem Update möglich."
  echo "Aktuell:    $(cat "$VERSION_FILE")"
  echo "Zurück auf: $(cat "$BACKUP_DIR$VERSION_FILE")"
  importer_running && warn "Ein Import läuft gerade; er beendet sich mit der alten Programmdatei normal."
  guard_system_files --rollback

  local template_changed=0 apache_changed=0 p swap="$STATE_DIR/swap"
  cmp -s "$BACKUP_DIR$IMPORTER_DIR/sql/template.sql" "$IMPORTER_DIR/sql/template.sql" || template_changed=1
  apache_files_differ "$BACKUP_DIR" && apache_changed=1

  # Eine Sicherung von vor den Prüfsummen hat keine: dann gilt danach keine.
  local drop_manifest=0
  [ -e "$BACKUP_DIR$MANIFEST" ] || drop_manifest=1

  # Tauschen: aktueller Stand -> swap, Sicherung -> System, swap -> neue Sicherung.
  # So macht ein zweites --rollback den Schritt wieder rückgängig.
  rm -rf "$swap"; install -d -m 700 "$swap"
  for p in "${MANAGED_PATHS[@]}"; do
    [ -e "$p" ] && copy_with_path "$p" "$swap"
  done
  for p in "${MANAGED_PATHS[@]}"; do
    # Was in der Sicherung fehlt, bleibt unangetastet (z. B. Apache-Dateien)
    [ -e "$BACKUP_DIR$p" ] || continue
    rm -rf "$p"
    cp -a "$BACKUP_DIR$p" "$(dirname "$p")/"
  done
  rm -rf "$BACKUP_DIR"; mv "$swap" "$BACKUP_DIR"
  [ "$drop_manifest" = 0 ] || rm -f "$MANIFEST"

  log "Template-Datenbank mit dem zurückgeholten Stand neu anlegen"
  (cd "$IMPORTER_DIR" && runuser -u "$SVC_USER" -- ./mv2mariadb --update)

  if [ "$HAVE_SYSTEMD" = 1 ]; then
    systemctl daemon-reload
    systemctl restart mediathek-api.service
  fi
  [ "$template_changed" = 1 ] && start_full_import "Datenbankstruktur hat sich geändert"
  if [ "$apache_changed" = 1 ]; then
    warn "Die Apache-Dateien haben sich geändert: apache2ctl configtest && systemctl reload apache2"
  fi

  cat <<EOF

Rollback fertig. Jetzt installiert: $(cat "$VERSION_FILE")
  Wieder vor:  $SELF --rollback
  Achtung: Ein normaler Lauf ohne Angaben installiert wieder den neuesten Stand.
  Um bei diesem Stand zu bleiben, ihn mitgeben: den Tag, wenn die Version
  oben genau einer Freigabe entspricht (z. B. REF=NI-2026.11), sonst den Commit
  hinter "repo=":
    sudo REF=<tag-oder-commit> $SELF
EOF
}

case "${1:-}" in
  "")          ;;
  --check)     do_check; exit 0 ;;
  --verify)    report_system_files; exit $? ;;
  --rollback)  do_rollback; exit 0 ;;
  -h|--help)   sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  *)           die "Unbekannte Option: $1 (erlaubt: --check, --verify, --rollback, --help)" ;;
esac

guard_system_files

# --------------------------------------------------------------------------
log "Pakete installieren"
export DEBIAN_FRONTEND=noninteractive
PKGS=(build-essential pkg-config git ca-certificates openssl
      libmariadb-dev libmariadb-dev-compat mariadb-client
      libcurl4-openssl-dev liblzma-dev libexpat1-dev rapidjson-dev
      libtidy-dev libjsoncpp-dev libboost-system-dev libfcgi-dev libssl-dev
      sassc lighttpd logrotate util-linux curl jq python3)
is_local_db && PKGS+=(mariadb-server)
LIGHTTPD_WAS_INSTALLED=0
dpkg-query -W -f='${Status}' lighttpd 2>/dev/null | grep -q "install ok installed" && LIGHTTPD_WAS_INSTALLED=1
apt-get update -qq
apt-get install -y -qq --no-install-recommends "${PKGS[@]}" >/dev/null

# Das Debian-Paket startet zusätzlich eine Standard-lighttpd-Instanz auf Port 80,
# die mit Apache kollidiert. Kam lighttpd erst durch dieses Skript auf den
# Server, wird diese Standardinstanz abgeschaltet.
if [ "$HAVE_SYSTEMD" = 1 ] && [ "$LIGHTTPD_WAS_INSTALLED" = 0 ]; then
  systemctl disable --now lighttpd.service >/dev/null 2>&1 || true
fi

# --------------------------------------------------------------------------
log "Systembenutzer anlegen ($SVC_USER, $WEB_USER)"
id "$SVC_USER" >/dev/null 2>&1 || useradd --system --home-dir "$IMPORTER_HOME" --shell /usr/sbin/nologin "$SVC_USER"
id "$WEB_USER" >/dev/null 2>&1 || useradd --system --home-dir "$API_HOME" --shell /usr/sbin/nologin "$WEB_USER"

# --------------------------------------------------------------------------
# Welcher Stand wird gebaut? REF hat Vorrang. Sonst: Stammt das Skript aus
# einem Checkout dieses Repos (nicht aus dem hier verwalteten Quellbaum), wird
# genau dessen Commit gebaut – Skript und Code passen dann zusammen.
REF_SOURCE="REF=${REF:-}"
if [ -z "${REF:-}" ]; then
  REF="origin/HEAD"
  REF_SOURCE="neuester Stand des Standard-Branches"
  self_git() { git -c safe.directory='*' -C "$(dirname "$SELF")" "$@"; }
  if top="$(self_git rev-parse --show-toplevel 2>/dev/null)" \
     && [ -d "$top/mediathek-db-import" ] && [ -d "$top/mediathek-api-dev" ] \
     && ! [ "$top" -ef "$REPO_DIR" ]; then
    REF="$(self_git rev-parse HEAD)"
    REF_SOURCE="Commit des Checkouts $top"
    if [ -n "$(self_git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
      warn "Der Checkout $top hat nicht committete Änderungen. Gebaut wird Commit ${REF:0:7} aus dem Repo auf GitHub; die Änderungen fließen nicht ein."
    fi
  fi
fi

log "Quellen holen bzw. aktualisieren ($SRC_DIR)"
echo "    Stand: $REF_SOURCE"
install -d -o "$SVC_USER" -g "$SVC_USER" "$SRC_DIR"
[ -d "$REPO_DIR/.git" ] || as_svc git clone -q "$REPO_URL" "$REPO_DIR"
as_svc git -C "$REPO_DIR" fetch -q --tags origin
as_svc git -C "$REPO_DIR" remote set-head origin -a >/dev/null
REF_SHOW="$REF"; [[ "$REF" =~ ^[0-9a-f]{40}$ ]] && REF_SHOW="${REF:0:7}"
as_svc git -C "$REPO_DIR" rev-parse -q --verify "$REF^{commit}" >/dev/null \
  || die "Stand '$REF_SHOW' gibt es im Repo auf GitHub nicht (Tippfehler oder noch nicht gepusht?)."
# Immer frisch auf den Zielstand wechseln; -f verwirft lokale Änderungen im
# Arbeitsbaum des verwalteten Quellbaums.
as_svc git -C "$REPO_DIR" checkout -q -f --detach "$REF"
REPO_REV="$(as_svc git -C "$REPO_DIR" rev-parse --short HEAD)"
# Versionskennung für beide Programme (sichtbar in /api/info und im
# User-Agent des Importers), abgeleitet vom letzten NI-Tag:
#   genau auf NI-2026.11          -> 2026.11
#   zwei Commits danach           -> 2026.11-2-g<commit>
BUILD_VERSION="$(build_version)"
echo "    $BUILD_VERSION: $(as_svc git -C "$REPO_DIR" log -1 --format='%h %cs %s')"

# --------------------------------------------------------------------------
# sass-Wrapper: das Makefile ruft die alte Ruby-sass-Syntax auf, wir nutzen sassc
render "$SYSTEM_DIR/build/sass" > "$SRC_DIR/sass"
chmod 755 "$SRC_DIR/sass"

# --------------------------------------------------------------------------
log "Importer (mv2mariadb) bauen"
render "$SYSTEM_DIR/build/mediathek-db-import.config.mk" > "$IMPORT_SRC/config.mk"
chown "$SVC_USER:" "$IMPORT_SRC/config.mk"
as_svc make -C "$IMPORT_SRC" clean >/dev/null
as_svc make -C "$IMPORT_SRC" -j"$(nproc)" IMPORTER_VERSION="$BUILD_VERSION"

log "API (mt-api) bauen"
render "$SYSTEM_DIR/build/mediathek-api-dev.config.mk" > "$API_SRC/config.mk"
chown "$SVC_USER:" "$API_SRC/config.mk"
as_svc make -C "$API_SRC" clean >/dev/null
as_svc make -C "$API_SRC" -j"$(nproc)" MT_API_VERSION="$BUILD_VERSION"

# --------------------------------------------------------------------------
# Ab hier wird installiert. Vorher die laufende Version sichern – aber nur,
# wenn sich der Stand ändert, damit ein Wiederholungslauf die Sicherung der
# echten Vorversion nicht überschreibt.
NEW_VERSION="version=$BUILD_VERSION repo=$REPO_REV script=$(sha256sum "$0" | cut -c1-12)"
TEMPLATE_CHANGED=0
if [ -x "$API_HOME/bin/mt-api" ]; then
  if [ "$(cat "$VERSION_FILE" 2>/dev/null)" = "$NEW_VERSION" ]; then
    if [ -f "$BACKUP_DIR$VERSION_FILE" ]; then
      log "Stand unverändert ($NEW_VERSION) – vorhandene Sicherung bleibt"
    else
      log "Stand unverändert ($NEW_VERSION) – noch keine Sicherung, Rollback erst nach dem nächsten Update möglich"
    fi
  else
    log "Laufende Version sichern ($(cat "$VERSION_FILE" 2>/dev/null || echo 'ohne Versionsangabe'))"
    backup_installed
    cmp -s "$IMPORT_SRC/src/sql/template.sql" "$IMPORTER_DIR/sql/template.sql" || TEMPLATE_CHANGED=1
  fi
fi

# --------------------------------------------------------------------------
log "Datenbank vorbereiten"
IMPORT_PW="${IMPORT_PW:-$(pw_from_file "$IMPORTER_DIR/pw_mariadb")}"
API_PW="${API_PW:-$(pw_from_file "$API_HOME/data/.passwd/sqlpasswd")}"

if is_local_db; then
  if [ "$HAVE_SYSTEMD" = 1 ]; then systemctl enable --now mariadb >/dev/null; fi
  IMPORT_PW="${IMPORT_PW:-$(randpw)}"
  API_PW="${API_PW:-$(randpw)}"
  check_credentials
  # Importer: darf mediathek_* anlegen/löschen. API: liest nur mediathek_1.
  mariadb <<EOF
CREATE USER IF NOT EXISTS '$IMPORT_USER'@'localhost' IDENTIFIED BY '$IMPORT_PW';
ALTER USER '$IMPORT_USER'@'localhost' IDENTIFIED BY '$IMPORT_PW';
GRANT ALL PRIVILEGES ON \`mediathek\\_%\`.* TO '$IMPORT_USER'@'localhost';
CREATE USER IF NOT EXISTS '$API_USER'@'localhost' IDENTIFIED BY '$API_PW';
ALTER USER '$API_USER'@'localhost' IDENTIFIED BY '$API_PW';
GRANT SELECT ON \`mediathek\\_1\`.* TO '$API_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
else
  [ -n "$IMPORT_PW" ] && [ -n "$API_PW" ] || die "Externer DB_HOST: bitte IMPORT_PW und API_PW angeben (Benutzer vorher anlegen)."
  check_credentials
  warn "Externe Datenbank $DB_HOST: Benutzer werden NICHT angelegt."
fi

# --------------------------------------------------------------------------
log "Importer nach $IMPORTER_HOME installieren"
install -d -m 755 "$MT_BASE"
install -d -o "$SVC_USER" -g "$SVC_USER" "$IMPORTER_HOME" "$IMPORTER_DIR" "$IMPORTER_DIR/dl" "$IMPORTER_DIR/sql"
install -m 755 -o "$SVC_USER" -g "$SVC_USER" "$IMPORT_SRC/build/mv2mariadb" "$IMPORTER_DIR/"
install -m 644 -o "$SVC_USER" -g "$SVC_USER" "$IMPORT_SRC"/src/sql/* "$IMPORTER_DIR/sql/"

CONF="$IMPORTER_DIR/mv2mariadb.conf"
if [ ! -f "$CONF" ]; then
  # Startkonfiguration wie im offiziellen mediathek-backend (quickstart.sh);
  # mv2mariadb ergänzt fehlende Schlüssel selbst. Der Download-Server ist
  # direkt eingetragen, falls die Serverliste beim ersten Lauf nicht erreichbar ist.
  # WICHTIG: testMode=false, sonst landen die Daten in mediathek_1_TEST.
  # Nur Startwert: mv2mariadb schreibt die Datei selbst fort, deshalb ohne
  # Prüfsumme.
  render "$SYSTEM_DIR$CONF" > "$CONF"
else
  sed -i "s/^mysqlHost=.*/mysqlHost=$DB_HOST/; s/^testMode=.*/testMode=false/" "$CONF"
fi
printf '%s:%s\n' "$IMPORT_USER" "$IMPORT_PW" > "$IMPORTER_DIR/pw_mariadb"
chown "$SVC_USER:" "$CONF" "$IMPORTER_DIR/pw_mariadb"
chmod 600 "$IMPORTER_DIR/pw_mariadb"

log "Template-Datenbank anlegen (mv2mariadb --update)"
(cd "$IMPORTER_DIR" && runuser -u "$SVC_USER" -- ./mv2mariadb --update)

if is_local_db; then
  # Wie im mediathek-backend: leere Tabellen in mediathek_1 aus dem Template,
  # damit die API schon vor dem ersten Import gültig (leer) antwortet.
  # Vorhandene Tabellen und Daten bleiben unberührt.
  mariadb <<'EOF'
CREATE DATABASE IF NOT EXISTS mediathek_1 DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE TABLE IF NOT EXISTS mediathek_1.video       LIKE mediathek_1_template.video;
CREATE TABLE IF NOT EXISTS mediathek_1.channelinfo LIKE mediathek_1_template.channelinfo;
CREATE TABLE IF NOT EXISTS mediathek_1.version     LIKE mediathek_1_template.version;
EOF
fi

# --------------------------------------------------------------------------
log "API nach $API_HOME installieren"
# Programm und Vorlagen gehören root (nicht beschreibbar für den Dienst),
# nur Log und Passwortdatei gehören $WEB_USER.
install -d "$API_HOME" "$API_HOME/bin" "$API_HOME/www" "$API_HOME/data"
install -d -o "$WEB_USER" -g "$WEB_USER" -m 750 "$API_HOME/log"
install -d -o "$WEB_USER" -g "$WEB_USER" -m 700 "$API_HOME/data/.passwd"
install -m 755 "$API_SRC/build/mt-api" "$API_HOME/bin/"
cp -a "$API_SRC/src/web/www/." "$API_HOME/www/"
rm -rf "$API_HOME/www/css" && cp -a "$API_SRC/build/src/css" "$API_HOME/www/"
cp -a "$API_SRC/src/web/data/template" "$API_HOME/data/"
install -m 755 "$API_SRC/docker/mt-api.cgi" "$API_HOME/www/mt-api.cgi"
# Der Wrapper aus dem Repo hat /opt/api fest eingetragen
sed -i "s|/opt/api\b|$API_HOME|g" "$API_HOME/www/mt-api.cgi"
grep -q "^exec $API_HOME/bin/mt-api" "$API_HOME/www/mt-api.cgi" \
  || die "mt-api.cgi aus dem Repo hat ein unerwartetes Format – Skript muss angepasst werden."
chown -R root:root "$API_HOME/bin" "$API_HOME/www" "$API_HOME/data/template"
printf '%s:%s\n' "$API_USER" "$API_PW" > "$API_HOME/data/.passwd/sqlpasswd"
chown "$WEB_USER:$WEB_USER" "$API_HOME/data/.passwd/sqlpasswd"
chmod 600 "$API_HOME/data/.passwd/sqlpasswd"

log "lighttpd-Konfiguration für die API schreiben"
put_file /etc/mediathek-api/lighttpd.conf
lighttpd -tt -f /etc/mediathek-api/lighttpd.conf >/dev/null

# --------------------------------------------------------------------------
log "systemd-Units schreiben"
put_file /etc/systemd/system/mediathek-api.service

# Zwei Importer-Units mit derselben Härtung: der stündliche Lauf und der
# Vollimport. Eine Sperrdatei verhindert, dass beide gleichzeitig laufen:
# der stündliche Lauf überspringt dann, der Vollimport wartet. Sperre 120 min
# nach dem letzten Download; der Timer ruft stündlich auf. Nach jedem
# erfolgreichen Lauf wird die WebTV-Liste neu geschrieben.
put_file /etc/systemd/system/mediathek-importer.service
put_file /etc/systemd/system/mediathek-importer-full.service
put_file /etc/systemd/system/mediathek-importer.timer

log "WebTV-Liste der Livestreams einrichten"
# Neutrino lädt WebTV-Listen auch von einer URL. Diese Liste enthält die
# Livestreams der API, so dass sie ohne das Mediathek-Plugin als Bouquet
# erscheinen. Sie wird aus der lokalen API erzeugt (gleiche Auswahl und
# Titel wie im Plugin, keine eigenen Datenbank-Zugangsdaten) und von Apache
# als statische Datei ausgeliefert. Das Skript best_bitrate_m3u8.lua gehört
# zu jedem NI-Image und wählt die Auflösung nach der Einstellung der Box.
# Für die EPG nennt jeder Eintrag den XMLTV-Guide (EPG_XMLTV) und seinen
# Kanal darin, nach livestreams-epg.tsv. Den Guide lädt die Box selbst; der
# Server holt ihn nicht.
put_file /opt/mediathek/api/bin/mediathek-webtv-xml
put_file /opt/mediathek/api/data/livestreams-epg.tsv

# Läuft nach jedem erfolgreichen Import (OnSuccess= der Importer-Units) und
# darf nur die lokale API erreichen und nur in $WEBTV_DIR schreiben.
put_file /etc/systemd/system/mediathek-webtv.service

log "Statistikseite einrichten"
# Liest das Apache-Zugriffslog der API (beide Adressen schreiben hinein) und
# schreibt eine statische Seite ohne Scripte. IP-Adressen werden nur gezählt;
# gespeichert werden je Tag allein Summen ($STATS_DIR/state.json).
put_file /opt/mediathek/api/bin/mediathek-stats
put_file /etc/systemd/system/mediathek-stats.service
put_file /etc/systemd/system/mediathek-stats.timer

log "Log-Rotation für die API einrichten"
# Ohne Rotation könnte jemand mit vielen Anfragen die Platte füllen.
put_file /etc/logrotate.d/mediathek-api

# --------------------------------------------------------------------------
if [ "$APACHE" = 1 ]; then
  log "Apache-Anbindung vorbereiten (VirtualHost wird nicht verändert)"
  put_file /etc/apache2/mediathek-api.inc

  if [ -n "$API_DOMAIN" ]; then
    install -d -m 755 "$ACME_ROOT"
    put_file /etc/apache2/sites-available/mediathek-api.conf
  fi

  put_file /etc/apache2/conf-available/mediathek-api-qos.conf

  # Apache nur anfassen, wenn seine Konfiguration vorher in Ordnung ist
  if ! apache2ctl configtest >/dev/null 2>&1; then
    apache2ctl configtest || true
    die "Die Apache-Konfiguration ist schon vor diesem Schritt fehlerhaft – bitte zuerst beheben. An Apache wurde nichts geändert."
  fi

  # Benötigte Module einschalten. Im Fehlerfall werden nur die wieder
  # abgeschaltet, die dieses Skript eingeschaltet hat.
  ENABLED_MODS=()
  for m in proxy proxy_http headers; do
    a2query -q -m "$m" || { a2enmod -q "$m" >/dev/null; ENABLED_MODS+=("$m"); }
  done
  if ! apache2ctl configtest >/dev/null 2>&1; then
    for m in "${ENABLED_MODS[@]}"; do a2dismod -q "$m" >/dev/null || true; done
    apache2ctl configtest || true
    die "Apache-Konfigurationstest fehlgeschlagen – eingeschaltete Module wieder abgeschaltet. Apache wurde nicht neu geladen."
  fi

  # vHost der Subdomain einschalten (bzw. ohne API_DOMAIN abschalten)
  if [ -n "$API_DOMAIN" ]; then
    SITE_WAS_ON=0; a2query -q -s mediathek-api && SITE_WAS_ON=1
    a2ensite -q mediathek-api >/dev/null
    if ! apache2ctl configtest >/dev/null 2>&1; then
      [ "$SITE_WAS_ON" = 1 ] || a2dissite -q mediathek-api >/dev/null || true
      apache2ctl configtest || true
      die "Apache-Konfigurationstest mit dem vHost für $API_DOMAIN fehlgeschlagen – wieder abgeschaltet. Apache wurde nicht neu geladen."
    fi
  else
    a2dissite -q mediathek-api >/dev/null 2>&1 || true
  fi

  # Begrenzung mit mod_qos (optional). Lässt es sich nicht laden, werden
  # Modul und Konfiguration vollständig zurückgenommen; die API läuft dann
  # ohne Begrenzung pro IP.
  QOS_ACTIVE=0
  if [ "$QOS" = 1 ] && install_mod_qos; then
    QOS_WAS_ON=0; a2query -q -m qos && QOS_WAS_ON=1
    a2enmod -q qos >/dev/null
    a2enconf -q mediathek-api-qos >/dev/null
    if apache2ctl configtest >/dev/null 2>&1; then
      QOS_ACTIVE=1
    else
      QOS_ERR="$(apache2ctl configtest 2>&1 | grep -i "qos" | head -2 || true)"
      a2disconf -q mediathek-api-qos >/dev/null || true
      [ "$QOS_WAS_ON" = 1 ] || a2dismod -q qos >/dev/null || true
      warn "mod_qos lässt sich nicht laden – Modul und Begrenzung wieder abgeschaltet:"
      printf '    %s\n' "$QOS_ERR" >&2
      apache2ctl configtest >/dev/null 2>&1 \
        || die "Apache-Konfiguration auch nach dem Zurücknehmen von mod_qos fehlerhaft – bitte prüfen (apache2ctl configtest)."
    fi
  fi
  if [ "$QOS_ACTIVE" = 0 ]; then
    a2disconf -q mediathek-api-qos >/dev/null 2>&1 || true
    warn "Weiter ohne Begrenzung pro IP (mod_qos). Die übrigen Schutzmaßnahmen sind aktiv."
  fi
fi

install -d -m 755 "$STATE_DIR"
echo "$NEW_VERSION" > "$VERSION_FILE"

# --------------------------------------------------------------------------
if [ "$HAVE_SYSTEMD" = 1 ]; then
  systemctl daemon-reload
  systemctl enable --now mediathek-api.service
  systemctl restart mediathek-api.service
  systemctl enable --now mediathek-importer.timer
  systemctl enable --now mediathek-stats.timer

  # Passwort nicht auf die Kommandozeile (wäre in der Prozessliste sichtbar)
  if is_local_db; then
    VIDEO_ROWS="$(mariadb -N -e 'SELECT COUNT(*) FROM mediathek_1.video' 2>/dev/null || true)"
  else
    VIDEO_ROWS="$(MYSQL_PWD="$API_PW" mariadb -h "$DB_HOST" -u "$API_USER" -N \
          -e 'SELECT COUNT(*) FROM mediathek_1.video' 2>/dev/null || true)"
  fi
  if [ "${SKIP_FIRST_IMPORT:-0}" != 1 ] && [ "${VIDEO_ROWS:-0}" = 0 ]; then
    start_full_import "erster Import, Download ~2 GB, dauert einige Minuten"
  elif [ "$TEMPLATE_CHANGED" = 1 ]; then
    start_full_import "Datenbankstruktur hat sich geändert"
  fi
else
  warn "systemd läuft nicht – Units geschrieben, aber nicht aktiviert."
fi

# --------------------------------------------------------------------------
log "Funktionstest der API"
SMOKE_OK=0
for _ in $(seq 15); do
  if curl -fsS --noproxy '*' -m 5 "http://127.0.0.1:$API_PORT/mt-api/api/info" 2>/dev/null | grep -q '"api":"mt-api"'; then
    SMOKE_OK=1; break
  fi
  sleep 1
done
if [ "$SMOKE_OK" = 1 ]; then
  echo "    OK: http://127.0.0.1:$API_PORT/mt-api/api/info liefert gültiges JSON"
else
  warn "Die API antwortet nicht wie erwartet. Prüfen: systemctl status mediathek-api, $API_HOME/log/error.log"
fi

if [ "$HAVE_SYSTEMD" = 1 ]; then
  log "WebTV-Liste der Livestreams schreiben"
  systemctl reset-failed mediathek-webtv.service 2>/dev/null || true
  if systemctl start mediathek-webtv.service; then
    echo "    OK: $WEBTV_DIR/livestreams.xml ($(grep -c '<webtv ' "$WEBTV_DIR/livestreams.xml") Livestreams)"
  else
    warn "WebTV-Liste noch nicht geschrieben (Datenbank leer?). Das passiert nach dem nächsten erfolgreichen Import von selbst."
  fi
  log "Statistikseite schreiben"
  systemctl reset-failed mediathek-stats.service 2>/dev/null || true
  systemctl start mediathek-stats.service \
    || warn "Statistikseite nicht geschrieben. Prüfen: journalctl -u mediathek-stats"
fi

cat <<EOF

Fertig. Lokaler Test:
  curl 'http://127.0.0.1:$API_PORT/mt-api/api/info'
EOF
if [ "$APACHE" = 1 ]; then
if [ "${QOS_ACTIVE:-0}" = 0 ] && [ "$QOS" = 1 ]; then
cat <<'EOF'

Begrenzung pro IP (mod_qos) ist NICHT aktiv. Unter Debian 12 die Backports
einrichten und das Skript erneut starten:
  echo "deb http://deb.debian.org/debian bookworm-backports main" \
    > /etc/apt/sources.list.d/bookworm-backports.list
  apt-get update
EOF
fi
if [ -n "$API_DOMAIN" ] && [ -f "/etc/letsencrypt/live/$API_DOMAIN/fullchain.pem" ]; then
cat <<EOF

Apache-Dateien neu geschrieben. Wirksam nach:
  apache2ctl configtest && systemctl reload apache2
Test:  curl https://$API_DOMAIN/api/info
WebTV-Liste für Neutrino:  https://$API_DOMAIN/livestreams.xml
Statistik:                 https://$API_DOMAIN/
EOF
elif [ -n "$API_DOMAIN" ]; then
cat <<EOF

Noch zu tun (einmalig, von Hand), für https://$API_DOMAIN:
  1. DNS: A-Eintrag (und ggf. AAAA) für $API_DOMAIN auf diesen Server.
  2. apache2ctl configtest && systemctl reload apache2
  3. Sobald der DNS-Eintrag gilt, das Zertifikat ausstellen:
       certbot certonly --webroot -w $ACME_ROOT -d $API_DOMAIN \\
         --deploy-hook "systemctl reload apache2"
  4. apache2ctl configtest && systemctl reload apache2
  5. Test:  curl https://$API_DOMAIN/api/info
  6. Basis-URL im Plugin:  https://$API_DOMAIN

  Die alte Adresse https://<hauptseite>/mt-api bleibt erreichbar, solange
  /etc/apache2/mediathek-api.inc im HTTPS-vHost der Hauptseite eingebunden ist.
EOF
else
cat <<'EOF'

Noch zu tun (einmalig, von Hand):
  1. In den HTTPS-VirtualHost der Hauptseite (z. B. in
     /etc/apache2/sites-available/<deine-site>-ssl.conf) innerhalb von
     <VirtualHost *:443> ... </VirtualHost> einfügen:
         Include /etc/apache2/mediathek-api.inc
  2. apache2ctl configtest && systemctl reload apache2
  3. Test:  curl https://<hauptseite>/mt-api/api/info
  4. Basis-URL im Plugin:  https://<hauptseite>/mt-api
EOF
fi
fi
cat <<EOF

Logs:
  Import:   journalctl -u mediathek-importer -u mediathek-importer-full
  WebTV:    journalctl -u mediathek-webtv
  Statistik: journalctl -u mediathek-stats
  API:      $API_HOME/log/error.log und $API_HOME/log/mt-api.requests.log
  Timer:    systemctl list-timers mediathek-importer.timer
EOF
