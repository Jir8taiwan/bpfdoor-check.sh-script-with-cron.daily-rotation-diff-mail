#!/usr/bin/env bash
# /usr/local/sbin/bpfdoor_daily_check.sh
# Daily non-invasive BPFDoor behavior check, diff, and mail report.
# Author: M365 Copilot for Jir Chung
# Date: 2025-11-21
export LC_ALL=C LANG=C
set -Eeuo pipefail

# --- Configuration ---
MAIL_TO="you@example.com"       # <<< CHANGE THIS to the recipient email address
MAIL_FROM="noreply@$(hostname -f)"
SUBJECT_PREFIX="[bpfdoor-check]"
LOGDIR="/var/log/bpfdoor-check"
STATE_LAST="${LOGDIR}/last_run.log"
DIFF_MAX_LINES=20000             # cap to avoid accidental huge mails

# Optional external config to override variables
## 可調變數（建議放進 /etc/default/bpfdoor-check）
## 可以把「標準端口」放進外部設定檔，改不同主機就不用改腳本：
## exmple
## /etc/default/bpfdoor-check
#STD_TCP_PORTS="21,22,25,80,110,139,143,443,445,465,587,5939,631,873,993,995,2222,3142,3306,5900,5901,6001,8891"
#STD_UDP_PORTS="53,67,68,111,123,137,138,5353,41641"
#
CONF_FILE="/etc/default/bpfdoor-check"
if [[ -f "$CONF_FILE" ]]; then
  # shellcheck source=/etc/default/bpfdoor-check
  source "$CONF_FILE"
fi

# --- Preconditions ---
mkdir -p "$LOGDIR"
chmod 0755 "$LOGDIR" || true
HOSTNAME_FQDN=$(hostname -f 2>/dev/null || hostname)
STAMP=$(date +%F_%H%M%S)
NEWLOG="${LOGDIR}/bpfdoor_check_${HOSTNAME_FQDN}_${STAMP}.log"
DIFFLOG="${LOGDIR}/diff_${STAMP}.txt"

# --- Collect Diagnostics ---
{
  echo "=== Host & Versions ==="
  uname -a
  if command -v lsb_release >/dev/null 2>&1; then lsb_release -a 2>/dev/null; else cat /etc/os-release; fi
  /usr/sbin/chkrootkit -V 2>/dev/null || echo "chkrootkit: version unknown"
  date -Iseconds

  echo; echo "=== Chrony ==="
  systemctl status chronyd --no-pager || true
  chronyc tracking || true

  echo; echo "=== BPF on sockets (ss -0bp) ==="
  ss -0bp || true

  echo; echo "=== bpftool net programs ==="
  if command -v bpftool >/dev/null 2>&1; then bpftool net || true; else echo "bpftool not found"; fi

  echo; echo "=== bpftool prog show (summary) ==="
  if command -v bpftool >/dev/null 2>&1; then bpftool prog show || true; else echo "bpftool not found"; fi

  echo; echo "=== iptables rules (filter/nat) ==="
  iptables -S || true
  iptables -t nat -S || true

  echo; echo "=== Grep /proc/*/stack for recvmsg signatures ==="
  grep -H -E "packet_recvmsg|seqpacket_recvmsg" /proc/*/stack 2>/dev/null | head -n 200 || true

  echo; echo "=== Deleted executables or /dev/shm binaries ==="
  ls -l /proc/*/exe 2>/dev/null | grep -E 'deleted|/dev/shm' || echo "No deleted/dev/shm executables found"

  echo; echo "=== Listening ports & owners ==="
  ss -lntp || true
  ss -lnup || true

  echo; echo "=== Recent kernel/journal mentions of iptables changes ==="
  journalctl -k --since "yesterday" | grep -i -E 'iptables|REDIRECT|PREROUTING' || echo "No journal hits (iptables)"
} | tee "$NEWLOG" >/dev/null


# --- Normalize log to reduce noise ---
CLEANLOG="${NEWLOG}.clean"
sed -E '
  s/^(date|Ref time.*|System time.*|Last offset.*|RMS offset.*|Frequency.*|Residual freq.*|Skew.*|Root delay.*|Root dispersion.*|Update interval.*)$/#NOISE REMOVED/g;
  s/^CPU:.*/#NOISE REMOVED/g;
  s/^[A-Za-z]{3} [0-9]{2} .*/#LOCALE DATE LINE/g;
' "$NEWLOG" > "$CLEANLOG"


# --- Diff with previous ---
LC_ALL=C
if [[ -f "$STATE_LAST" ]]; then
  if [[ ! -r "$STATE_LAST" ]]; then
    {
      printf "(diff error) STATE_LAST exists but is not readable: %s\n" "$STATE_LAST"
      printf "Permissions:\n"
      ls -l "$STATE_LAST" 2>&1
    } > "$DIFFLOG"
  else
    # 直接把 stderr 併入 DIFFLOG，避免錯誤訊息丟失
    if diff -u "$STATE_LAST" "$NEWLOG" > "$DIFFLOG" 2>&1; then
      # 相同：diff 退出碼 0，DIFFLOG 可能是空檔；補上可讀訊息
      if [[ ! -s "$DIFFLOG" ]]; then
        printf "No differences since last run (%s).\n" "$STAMP" > "$DIFFLOG"
      fi
    else
      status=$?
      if (( status == 1 )); then
        # 有差異：這是正常情況，DIFFLOG 已包含差異
        :
      else
        # 真正錯誤（>1）：把上下文一併寫入
        {
          echo "(diff produced non-zero exit (>1); check formats/paths/permissions)"
          echo
          echo "=== CONTEXT ==="
          echo "diff status: $status"
          echo "diff: $(command -v diff || echo 'not found')"
          (diff --version 2>/dev/null || busybox diff --help 2>/dev/null || true)
          echo
          echo "=== FILE STAT ==="
          echo "[STATE_LAST]"
          ls -l "$STATE_LAST" || true
          file "$STATE_LAST" || true
          echo "[NEWLOG]"
          ls -l "$NEWLOG" || true
          file "$NEWLOG" || true
          echo
          echo "=== RAW DIFF/STDERR OUTPUT ==="
          cat "$DIFFLOG" || true
        } > "$DIFFLOG"
      fi
    fi
  fi
else
  echo "No previous run found. Baseline initialized on ${STAMP}." > "$DIFFLOG"
fi

#rm -f "$ERRLOG" 2>/dev/null || true



# Cap diff size to avoid flooding
DIFF_SIZE=$(wc -c < "$DIFFLOG" 2>/dev/null || echo 0)
if (( DIFF_SIZE > 0 )); then
  if (( DIFF_SIZE > 10485760 )); then
    #echo "\n[NOTE] Diff larger than 10MB; truncating to ${DIFF_MAX_LINES} lines." >> "$DIFFLOG"
    printf "\n[NOTE] Diff larger than 10MB; truncating to %d lines.\n" "$DIFF_MAX_LINES" >> "$DIFFLOG"
    # keep head
    head -n "$DIFF_MAX_LINES" "$DIFFLOG" > "${DIFFLOG}.tmp" && mv "${DIFFLOG}.tmp" "$DIFFLOG"
  fi
fi


# --- Build a concise risk summary and prepend to DIFFLOG ---
# Configuration: define what is "standard" for your host (can be overridden in CONF_FILE)
# Standard TCP listening ports (e.g., web/mail/ssh/db/print/vnc/etc.)
STD_TCP_PORTS="${STD_TCP_PORTS:-21,22,25,80,110,139,143,443,445,465,587,5939,631,873,993,995,2222,3142,3306,5900,5901,6001,8891}"
# Standard UDP listening ports (mostly service beacons; keep minimal)
STD_UDP_PORTS="${STD_UDP_PORTS:-53,67,68,111,123,137,138,5353,41641}"

# Helper to test membership (comma-separated list)
in_csv_list() {
  # $1=needle, $2=list "a,b,c"
  case ",$2," in
    *,"$1",*) return 0 ;;
    *) return 1 ;;
  esac
}

SUMMARY="$(mktemp)"

# --- Parse DIFF for BPF additions ---
# Count and list newly-added BPF programs from unified diff (+ lines).
# We consider lines like: "+1714: cgroup_skb name sd_fw_egress ..." or "+43: cgroup_device tag ..."
mapfile -t BPF_ADDED < <(awk '
  # Only consider new lines
  /^\+/ {
    # XDP/TC programs are typically shown by `bpftool prog show` lines like "+<id>: <type> ..."
    if ($0 ~ /^\+[0-9]+:\s/ || $0 ~ /^\+ *name /) {
      # Normalize: remove leading "+"
      line=substr($0,2);
      # Capture "type" and optional "name" tokens
      # e.g., "1714: cgroup_skb name sd_fw_egress tag ..."
      type=""; name="";
      # Split fields
      n=split(line, f, /[[:space:]]+/);
      # first token (id:) f[1], type f[2], then maybe "name" f[3] and the name f[4]
      if (n>=2) { type=f[2]; }
      for (i=3;i<=n;i++) {
        if (f[i]=="name" && (i+1)<=n) { name=f[i+1]; break; }
      }
      if (name!="") {
        printf("%s (%s)\n", name, type);
      } else if (type!="") {
        printf("%s\n", type);
      }
    }
  }
' "$DIFFLOG" | sort -u)

BPF_COUNT=${#BPF_ADDED[@]}

# --- Parse DIFF for socket additions and filter non-standard ---
# We look for "+LISTEN ..." only, extract the port and report if not in STD list.
mapfile -t LISTEN_ADDED < <(awk '
  # Example lines:
  # +LISTEN 0 511 *:80 *:* users:(("apache2"...))
  # +LISTEN 0 4096 0.0.0.0:631 0.0.0.0:* users:(("cupsd"...))
  /^\+LISTEN/ {
    # Normalize: remove leading "+"
    line=substr($0,2);
    # Try to catch token with "addr:port"
    # We search the first token that contains ":" followed by digits (port)
    n=split(line, f, /[[:space:]]+/);
    port="";
    for (i=1;i<=n;i++) {
      if (f[i] ~ /:[0-9]+$/) {
        # Extract the number after last ":"
        m=match(f[i], /:([0-9]+)$/);
        if (m) { port=substr(f[i], RSTART+1, RLENGTH-1); break; }
      }
    }
    proc="";
    # Grab process token if present
    # There is a trailing "users:(("proc_name"...))"
    m=match(line, /users:\(\( *"([^"]+)"/);
    if (m) {
      proc=substr(line, RSTART+8, RLENGTH-9); # crude extract of first quoted proc name
    }
    if (port!="") {
      # Print "port proc raw_line"
      printf("%s\t%s\t%s\n", port, proc, line);
    }
  }
' "$DIFFLOG")

# Split TCP vs IPv6 vs wildcard is messy in ss; for "standard vs abnormal" we only use port number.
ABNORMAL_LISTEN=()
for entry in "${LISTEN_ADDED[@]}"; do
  port="${entry%%$'\t'*}"
  # Determine protocol guess: ss -lntp shows TCP; ss -lnup shows UDP; but we merged both.
  # We cannot reliably tell here; we check both lists.
  if in_csv_list "$port" "$STD_TCP_PORTS" || in_csv_list "$port" "$STD_UDP_PORTS"; then
    continue
  fi
  ABNORMAL_LISTEN+=("$entry")
done

ABNORMAL_COUNT=${#ABNORMAL_LISTEN[@]}

# --- Check for iptables REDIRECT/DNAT additions ---
IPT_REDIRECT_COUNT=$(
  awk '/^\+/ && /-j[[:space:]]+REDIRECT/ {c++}
       /^\+/ && /-j[[:space:]]+DNAT/      {c++}
       END {print c+0}' "$DIFFLOG"
)

# --- Compute risk level ---
# Heuristic:
#   RED: any REDIRECT/DNAT added OR >=5 abnormal listening ports OR >=5 unknown BPF programs
#   YEL: 1-4 abnormal ports OR 1-4 unknown BPF programs
#   GRN: none of the above
RISK="GREEN"
if (( IPT_REDIRECT_COUNT > 0 )) || (( ABNORMAL_COUNT >= 5 )) || (( BPF_COUNT >= 5 )); then
  RISK="RED"
elif (( ABNORMAL_COUNT >= 1 )) || (( BPF_COUNT >= 1 )); then
  RISK="YELLOW"
fi

# --- Render summary ---
{
  echo "=== Risk Summary (host: ${HOSTNAME_FQDN}, at ${STAMP}) ==="
  echo "Risk Level: ${RISK}"
  echo
  echo "BPF programs added: ${BPF_COUNT}"
  if (( BPF_COUNT > 0 )); then
    printf "  - %s\n" "${BPF_ADDED[@]}"
  fi
  echo
  echo "New LISTEN ports (non-standard only): ${ABNORMAL_COUNT}"
  if (( ABNORMAL_COUNT > 0 )); then
    # Show as "port - process - raw"
    for row in "${ABNORMAL_LISTEN[@]}"; do
      port="${row%%$'\t'*}"
      rest="${row#*$'\t'}"
      proc="${rest%%$'\t'*}"
      raw="${row##*$'\t'}"
      printf "  - %s\t(%s)\n" "$port" "${proc:-unknown}"
    done
  fi
  echo
  echo "iptables REDIRECT/DNAT added in diff: ${IPT_REDIRECT_COUNT}"
  echo
  echo "Notes:"
  echo "  - GREEN: no redirects/dnat and no abnormal ports/programs."
  echo "  - YELLOW: small changes worth a glance."
  echo "  - RED: investigate (redirects/dnat present or many abnormal ports/programs)."
} > "$SUMMARY"

# Prepend summary then the original diff/content
cat "$DIFFLOG" > "${DIFFLOG}.orig" && { cat "$SUMMARY"; echo; cat "${DIFFLOG}.orig"; } > "$DIFFLOG"




# --- Send mail ---
send_mail() {
  local subject bodyfile
  subject="$SUBJECT_PREFIX ${HOSTNAME_FQDN} daily diff ${STAMP}"
  bodyfile="$1"
  if [[ -z "$MAIL_TO" || "$MAIL_TO" == "you@example.com" ]]; then
    echo "[WARN] MAIL_TO not configured. Set MAIL_TO in $CONF_FILE or script header." >&2
    return 1
  fi
  if command -v sendmail >/dev/null 2>&1; then
    {
      echo "From: ${MAIL_FROM}"
      echo "To: ${MAIL_TO}"
      echo "Subject: ${subject}"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo
      cat "$bodyfile"
    } | sendmail -t
    return $?
  elif command -v mail >/dev/null 2>&1; then
    mail -s "$subject" "$MAIL_TO" < "$bodyfile"
    return $?
  else
    echo "[WARN] No sendmail/mail command found. Skipping email." >&2
    return 2
  fi
}

send_mail "$DIFFLOG" || true

# --- Update baseline ---
# 確保 NEWLOG 可讀、STATE_LAST 可寫
if [[ -r "$NEWLOG" ]]; then
  if cp -f "$NEWLOG" "$STATE_LAST"; then
    chmod 0644 "$STATE_LAST" || true
  else
    printf "[WARN] Failed to update baseline: %s -> %s\n" "$NEWLOG" "$STATE_LAST" >&2
  fi
else
  printf "[WARN] NEWLOG not readable (skip baseline update): %s\n" "$NEWLOG" >&2
fi

# --- Permissions ---
chmod 0644 "$NEWLOG" "$DIFFLOG" "$STATE_LAST" || true

exit 0

