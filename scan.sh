#!/bin/sh
# What's-on-my-network scan. MODE=fast (passive, instant) or MODE=deep (sweep+probe).
MODE="${1:-deep}"

command -v jq >/dev/null 2>&1 || { echo '##NOJQ'; exit 0; }
command -v ip >/dev/null 2>&1 || { echo '##NOIP'; exit 0; }

TMP="$(mktemp -d)" || exit 0
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- interface
RT="$(ip -j route show default 2>/dev/null)"
IF="$(printf '%s' "$RT" | jq -r 'map(select(.dev != null))[0].dev // empty' 2>/dev/null)"
GW="$(printf '%s' "$RT" | jq -r 'map(select(.gateway != null))[0].gateway // empty' 2>/dev/null)"

# No default route: fall back to the first up, non-loopback IPv4 interface.
[ -n "$IF" ] || IF="$(ip -j -4 addr show up 2>/dev/null | jq -r '[.[] | select(.ifname != "lo" and (.addr_info|length) > 0)][0].ifname // empty')"
[ -n "$IF" ] || { echo '##NONET'; exit 0; }

ADDR="$(ip -j -4 addr show dev "$IF" 2>/dev/null | jq -r '[.[].addr_info[]? | select(.family=="inet" and .scope=="global")][0] | if . == null then "" else "\(.local) \(.prefixlen)" end')"
SELF="${ADDR% *}"
PLEN="${ADDR#* }"
[ -n "$SELF" ] && [ "$SELF" != "$ADDR" ] || { echo '##NONET'; exit 0; }

BASE="${SELF%.*}"
# Anything wider than a /24 is swept as the local /24 only — a /16 ping sweep
# would take minutes. PARTIAL tells the panel to say so.
PARTIAL=false
[ "$PLEN" -lt 24 ] 2>/dev/null && PARTIAL=true
CIDR="$BASE.0/$( [ "$PLEN" -ge 24 ] && echo "$PLEN" || echo 24 )"

jq -cn --arg if "$IF" --arg cidr "$CIDR" --arg self "$SELF" --arg gw "$GW" \
       --argjson partial "$PARTIAL" --arg mode "$MODE" \
  '{ifname:$if,cidr:$cidr,self:$self,gateway:$gw,partial:$partial,mode:$mode}' \
  | sed 's/^/##IF /'

# ------------------------------------------------------------- ping sweep
# Deep mode only. Every ping emits an ARP request first, so hosts that drop
# ICMP still land in the neighbour table — this is what makes the sweep find
# more than the passive cache.
: > "$TMP/ttl"
if [ "$MODE" = deep ]; then
  i=1
  n=0
  while [ "$i" -le 254 ]; do
    # The reply TTL is a free OS hint, so the per-packet line is kept (no -q)
    # and the value recorded. 64 = Linux/macOS/BSD, 128 = Windows, 255 =
    # network gear, minus hops — which is 0 on our own segment.
    ( t="$(ping -n -c1 -W1 "$BASE.$i" 2>/dev/null | sed -n 's/.*[^0-9a-z]ttl=\([0-9]*\).*/\1/p' | head -1)"
      [ -n "$t" ] && printf '%s %s\n' "$BASE.$i" "$t" >> "$TMP/ttl" ) &
    n=$((n + 1))
    # Bounded fan-out: 254 simultaneous processes is fine here but not on
    # every box, and the batch wait costs nothing (each ping caps at -W1).
    [ $((n % 128)) -eq 0 ] && wait
    i=$((i + 1))
  done
  wait
fi

# --------------------------------------------------------------- neighbours
# Reachable/stale/etc with a hardware address = alive on this segment.
ip -j neigh show dev "$IF" 2>/dev/null \
  | jq -r '.[] | select(.lladdr != null)
           | select((.state // []) | index("FAILED") | not)
           | "\(.dst) \(.lladdr)"' \
  | sort -t. -k4 -n > "$TMP/neigh"

# This machine is not in its own neighbour table — add it.
SELFMAC="$(cat "/sys/class/net/$IF/address" 2>/dev/null)"
printf '%s %s\n' "$SELF" "${SELFMAC:-00:00:00:00:00:00}" >> "$TMP/neigh"
sort -u -t' ' -k1,1 "$TMP/neigh" | sort -t. -k4 -n > "$TMP/hosts"

# ------------------------------------------------------------------ vendors
# One pass over the 6MB IEEE list rather than a grep per host. Locally
# administered addresses (bit 1 of the first octet) are randomised privacy
# MACs and have no vendor at all — flagged rather than looked up.
: > "$TMP/pfx"
while read -r ip mac; do
  [ -n "$mac" ] || continue
  printf '%s\n' "$mac" | tr 'a-f:' 'A-F-' | cut -c1-8 >> "$TMP/pfx"
done < "$TMP/hosts"
sort -u "$TMP/pfx" > "$TMP/pfx.u"
if [ -s "$TMP/pfx.u" ] && [ -r /usr/share/hwdata/oui.txt ]; then
  grep -F -f "$TMP/pfx.u" /usr/share/hwdata/oui.txt 2>/dev/null \
    | grep '(hex)' \
    | sed 's/[[:space:]]*(hex)[[:space:]]*/\t/' > "$TMP/oui"
fi
[ -f "$TMP/oui" ] || : > "$TMP/oui"

vendor_of() {
  _mac="$(printf '%s' "$1" | tr 'a-f:' 'A-F-')"
  _o1="$(printf '%s' "$_mac" | cut -c1-2)"
  # Second-least-significant bit of octet 1 set => locally administered.
  case "$_o1" in
    ?[26AEae]) printf '%s' '(randomised)'; return ;;
  esac
  _p="$(printf '%s' "$_mac" | cut -c1-8)"
  _v="$(awk -F'\t' -v p="$_p" '$1 == p {print $2; exit}' "$TMP/oui")"
  # 854 prefixes in oui.txt are MA-M/MA-S placeholders owned by the registry
  # itself; the real assignee lives in files hwdata does not ship, so there is
  # nothing to resolve — better blank than a meaningless "IEEE Registration
  # Authority".
  case "$_v" in "IEEE Registration Authority") _v="" ;; esac
  printf '%s' "$_v"
}

# --------------------------------------------------------------------- mDNS
# --no-db-lookup keeps service types as raw _service._tcp strings (parseable);
# field 7 is the DNS hostname, which avoids avahi's octal-escaped display name.
: > "$TMP/mdns"
if command -v avahi-browse >/dev/null 2>&1; then
  timeout 4 avahi-browse -atrp --no-db-lookup 2>/dev/null \
    | awk -F';' '$1 == "=" && $3 == "IPv4" && $8 != "" {
        model = ""
        if (match($0, /model=[^" ]+/))     model = substr($0, RSTART + 6, RLENGTH - 6)
        else if (match($0, /am=[^" ]+/))   model = substr($0, RSTART + 3, RLENGTH - 3)
        host = $7; sub(/\.local$/, "", host)
        print $8 "\t" host "\t" $5 "\t" model
      }' > "$TMP/mdns"
fi

# ---------------------------------------------------------------- port probe
# Deep mode only. Ports chosen to name a device, not to audit it.
PORTS="22 53 80 139 443 445 548 631 1883 3389 5000 5357 8006 8080 8096 8123 9100 32400"
: > "$TMP/ports"
if [ "$MODE" = deep ] && command -v nc >/dev/null 2>&1; then
  n=0
  while read -r ip mac; do
    [ "$ip" = "$SELF" ] && continue
    for p in $PORTS; do
      ( nc -z -w1 "$ip" "$p" >/dev/null 2>&1 && printf '%s %s\n' "$ip" "$p" >> "$TMP/ports" ) &
    done
    # Ports for one host go out together; hosts are batched so a 60-device
    # network doesn't fork a thousand sockets at once.
    n=$((n + 1))
    [ $((n % 8)) -eq 0 ] && wait
  done < "$TMP/hosts"
  wait
  # Own machine: ask the kernel rather than talking to ourselves. Only
  # listeners actually reachable from the LAN count — a loopback-bound CUPS
  # or stub resolver is not "open on the network" and must not be reported as
  # though a scanner saw it.
  ss -H -ltn 2>/dev/null | awk -v self="$SELF" '
    { a = $4
      sub(/%[^:]*$/, "", a)
      port = a; sub(/^.*:/, "", port)
      host = a; sub(/:[^:]*$/, "", host)
      gsub(/[][]/, "", host)
      if (host == "0.0.0.0" || host == "*" || host == "::" || host == self) print port
    }' | sort -un > "$TMP/selfports"
  for p in $PORTS; do
    grep -qx "$p" "$TMP/selfports" 2>/dev/null && printf '%s %s\n' "$SELF" "$p" >> "$TMP/ports"
  done
fi

# -------------------------------------------------------------- banners
# What a service volunteers the moment you connect. No extra hosts are
# contacted and no new ports are touched — only ports already found open are
# read. An SSH banner frequently names the distro outright
# ("...OpenSSH_8.9p1 Ubuntu-3ubuntu0.10"); an HTTP Server header pins embedded
# firmware exactly ("httpd/2.7 (Netgear; D86)").
: > "$TMP/banner"
if [ "$MODE" = deep ] && command -v nc >/dev/null 2>&1; then
  n=0
  while read -r ip mac; do
    [ "$ip" = "$SELF" ] && continue

    if grep -qx "$ip 22" "$TMP/ports" 2>/dev/null; then
      # Only a real identification string counts. A host running access
      # control answers port 22 with prose ("Not allowed at this time"),
      # which is not a banner and must not be read as one.
      ( b="$(timeout 2 nc "$ip" 22 </dev/null 2>/dev/null | head -1 | tr -d '\r\n' | cut -c1-100)"
        case "$b" in
          SSH-*) printf '%s\tssh\t%s\n' "$ip" "$b" >> "$TMP/banner" ;;
        esac ) &
    fi

    if grep -qx "$ip 80" "$TMP/ports" 2>/dev/null; then
      ( h="$(printf 'HEAD / HTTP/1.0\r\nHost: %s\r\n\r\n' "$ip" \
             | timeout 2 nc "$ip" 80 2>/dev/null \
             | grep -im1 '^server:' | sed 's/^[Ss]erver:[[:space:]]*//' \
             | tr -d '\r\n' | cut -c1-100)"
        [ -n "$h" ] && printf '%s\thttp\t%s\n' "$ip" "$h" >> "$TMP/banner" ) &
    fi

    n=$((n + 1))
    [ $((n % 8)) -eq 0 ] && wait
  done < "$TMP/hosts"
  wait
fi

# ------------------------------------------------------------- ssh config
# Reverse map of the user's ~/.ssh/config: alias -> HostName. Offering
# "ssh <address>" is usually wrong, because it logs in as the local user;
# the config entry pointing at that address knows the right User, Port and key.
# Wildcard patterns are skipped (they match everything and name nothing), and
# Include directives are not followed.
: > "$TMP/sshcfg"
if [ -r "$HOME/.ssh/config" ]; then
  awk '
    function flush(  i) {
      if (n > 0) for (i = 1; i <= n; i++) print aliases[i] "\t" hn
      n = 0; hn = ""
    }
    tolower($1) == "host" {
      flush()
      for (i = 2; i <= NF; i++) if ($i !~ /[*?!]/) aliases[++n] = $i
      next
    }
    tolower($1) == "hostname" { hn = $2; next }
    END { flush() }
  ' "$HOME/.ssh/config" 2>/dev/null > "$TMP/sshcfg"

  while IFS='	' read -r alias hn; do
    [ -n "$alias" ] || continue
    jq -cn --arg alias "$alias" --arg host "$hn" '{alias:$alias,host:$host}' \
      | sed 's/^/##SSHCFG /'
  done < "$TMP/sshcfg"
fi

# ------------------------------------------------------------- name cache
# Reverse DNS here comes from the router's DHCP table and answers only
# sometimes — a Windows box may resolve as DESKTOP-XXXXXXX on
# one scan and not at all on the next, which is the difference between
# identifying it and calling it "a computer". Names are therefore remembered
# against the MAC, which is the stable identity, and reused when a later scan
# draws a blank. Cached names are flagged so the panel can say so.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-network-scan"
CACHE="$CACHE_DIR/names.tsv"
mkdir -p "$CACHE_DIR" 2>/dev/null
[ -f "$CACHE" ] || : > "$CACHE" 2>/dev/null
: > "$TMP/learned"

# ------------------------------------------------------------------ emit
while read -r ip mac; do
  [ -n "$ip" ] || continue

  name="$(awk -F'\t' -v i="$ip" '$1 == i && $2 != "" {print $2; exit}' "$TMP/mdns")"
  model="$(awk -F'\t' -v i="$ip" '$1 == i && $4 != "" {print $4; exit}' "$TMP/mdns")"
  svcs="$(awk -F'\t' -v i="$ip" '$1 == i {print $3}' "$TMP/mdns" | sort -u | paste -sd, -)"
  ports="$(awk -v i="$ip" '$1 == i {print $2}' "$TMP/ports" | sort -un | paste -sd, -)"
  vend="$(vendor_of "$mac")"

  # Unicast reverse DNS only if mDNS drew a blank (router-provided names).
  if [ -z "$name" ] && [ "$MODE" = deep ]; then
    name="$(timeout 1 getent hosts "$ip" 2>/dev/null | awk '{print $2; exit}')"
    case "$name" in *.*) name="${name%%.*}" ;; esac
  fi
  [ "$ip" = "$SELF" ] && [ -z "$name" ] && name="$(hostname 2>/dev/null)"

  # Learn a fresh name, or fall back to one learned earlier for this MAC.
  CACHED=false
  if [ -n "$name" ]; then
    printf '%s\t%s\n' "$mac" "$name" >> "$TMP/learned"
  else
    name="$(awk -F'\t' -v m="$mac" '$1 == m {print $2; exit}' "$CACHE" 2>/dev/null)"
    [ -n "$name" ] && CACHED=true
  fi

  ttl="$(awk -v i="$ip" '$1 == i {print $2; exit}' "$TMP/ttl")"
  sshb="$(awk -F'\t' -v i="$ip" '$1 == i && $2 == "ssh" {print $3; exit}' "$TMP/banner")"
  httpb="$(awk -F'\t' -v i="$ip" '$1 == i && $2 == "http" {print $3; exit}' "$TMP/banner")"

  jq -cn --arg ip "$ip" --arg mac "$mac" --arg vendor "$vend" --arg name "$name" \
         --arg model "$model" --arg svcs "$svcs" --arg ports "$ports" \
         --arg ttl "$ttl" --arg ssh "$sshb" --arg http "$httpb" \
         --argjson cached "$CACHED" \
         --argjson self "$( [ "$ip" = "$SELF" ] && echo true || echo false )" \
         --argjson gw "$( [ "$ip" = "$GW" ] && echo true || echo false )" \
    '{ip:$ip,mac:$mac,vendor:$vendor,name:$name,model:$model,
      services:($svcs | if . == "" then [] else split(",") end),
      ports:($ports | if . == "" then [] else split(",") | map(tonumber) end),
      ttl:($ttl | if . == "" then null else tonumber end),
      ssh:$ssh,http:$http,cached:$cached,
      self:$self,gw:$gw}' | sed 's/^/##DEV /'
done < "$TMP/hosts"

# ------------------------------------------------------------- tailscale
if command -v tailscale >/dev/null 2>&1; then
  TS="$(timeout 3 tailscale status --json 2>/dev/null)"
  if [ -n "$TS" ]; then
    printf '%s' "$TS" | jq -r '
      (.BackendState // "") as $st
      | if $st != "Running" then "##TSOFF " + $st
        else
          ((.Self // {}) | "##TSSELF " + ({name:(.HostName // ""),
                                           ip:((.TailscaleIPs // [])[0] // ""),
                                           os:(.OS // "")} | tostring)),
          ((.Peer // {}) | to_entries | sort_by(.value.HostName // "")[]
            | .value
            | "##TS " + ({name:(.HostName // ""),
                          dns:((.DNSName // "") | sub("\\.$";"")),
                          ip:((.TailscaleIPs // [])[0] // ""),
                          os:(.OS // ""),
                          online:(.Online == true),
                          exitNode:(.ExitNodeOption == true),
                          # sshHostKeys is only present when the peer has
                          # Tailscale SSH turned on, which means `tailscale ssh`
                          # authenticates through the tailnet with no key of
                          # ours involved.
                          tsSSH:(((.sshHostKeys // []) | length) > 0)} | tostring))
        end' 2>/dev/null
  fi
fi

# Merge names learned this run over the existing cache (new entries win), and
# cap it so a network with churning DHCP can't grow the file without bound.
if [ -s "$TMP/learned" ] && [ -w "$CACHE" ]; then
  cat "$TMP/learned" "$CACHE" 2>/dev/null \
    | awk -F'\t' 'NF == 2 && !seen[$1]++' | head -n 500 > "$TMP/cache.new"
  [ -s "$TMP/cache.new" ] && mv "$TMP/cache.new" "$CACHE"
fi

echo '##END'
