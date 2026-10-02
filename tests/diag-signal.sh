#!/bin/bash
# Temporary diagnostic (not for merge): which hardening flag makes tini's SIGTERM forwarding fail under Podman.
set -uo pipefail
img=aspia-server:ci
docker save "$img" | sudo podman load -q
sudo podman info --format 'podman {{.Version.Version}}; apparmor {{.Host.Security.AppArmorEnabled}}; selinux {{.Host.Security.SELinuxEnabled}}'
caps="--cap-drop=all --cap-add=chown --cap-add=dac_override --cap-add=setuid --cap-add=setgid --cap-add=kill"
declare -a names=(none caps nnp readonly pids caps+nnp all all+unconfined all-but-nnp)
declare -a flags=(""
  "$caps"
  "--security-opt=no-new-privileges"
  "--read-only --read-only-tmpfs=false"
  "--pids-limit=128"
  "$caps --security-opt=no-new-privileges"
  "$caps --security-opt=no-new-privileges --read-only --read-only-tmpfs=false --pids-limit=128"
  "$caps --security-opt=no-new-privileges --read-only --read-only-tmpfs=false --pids-limit=128 --security-opt=apparmor=unconfined"
  "$caps --read-only --read-only-tmpfs=false --pids-limit=128")
for i in "${!names[@]}"; do
  n="diag-${i}"
  # shellcheck disable=SC2086
  sudo podman run -d --name "$n" -e EXTERNAL_IP=203.0.113.10 ${flags[$i]} "$img" > /dev/null
  for _ in $(seq 60); do sudo podman logs "$n" 2>&1 | grep -q 'Router: relays' && break; sleep 1; done
  prof="$(sudo podman inspect -f '{{.AppArmorProfile}}' "$n")"
  attr="$(sudo podman exec "$n" cat /proc/1/attr/current 2>/dev/null)"
  sudo podman stop -t 10 "$n" > /dev/null 2>&1
  if sudo podman logs "$n" 2>&1 | grep -q 'All processes have exited; exit code 0'; then r=CLEAN
  elif sudo podman logs "$n" 2>&1 | grep -q 'FATAL tini'; then r="TINI-FAIL: $(sudo podman logs "$n" 2>&1 | grep 'FATAL tini' | head -1)"
  else r="OTHER: $(sudo podman logs "$n" 2>&1 | tail -2 | tr '\n' ' ')"; fi
  printf '%-16s profile=%-22s attr=%-28s %s\n' "${names[$i]}" "$prof" "$attr" "$r"
  sudo podman rm -f "$n" > /dev/null
done
echo "--- kernel log (apparmor):"
sudo journalctl -k --since "-15 min" --no-pager | grep -i apparmor | tail -20
echo "--- containers-default profile signal rules:"
sudo grep -rn 'signal' /etc/apparmor.d/ 2>/dev/null | grep -i contain | head; sudo aa-status 2>/dev/null | grep -i contain | head
