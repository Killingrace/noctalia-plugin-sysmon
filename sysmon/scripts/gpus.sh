#!/bin/sh
# gpus.sh - list display adapters for the sysmon System tab without waking them.
#
# Deliberately NOT lspci: lspci reads each device's PCI config space, and the
# kernel resumes a D3cold device for that read - on a hybrid laptop that powers
# the sleeping discrete GPU up. vendor/device/class/boot_vga are cached by the
# PCI core, the driver is a symlink and power/runtime_status is served by the
# PM core, so nothing here touches the hardware. Names come from pci.ids.
#
# Output, one tab-separated line per adapter:
#   sysfsPath slot vendorId deviceId driver bootVga hwmonDir vendorName deviceName

ids=""
for f in /usr/share/hwdata/pci.ids /usr/share/misc/pci.ids /usr/share/pci.ids; do
  [ -r "$f" ] && ids=$f && break
done

for d in /sys/bus/pci/devices/*; do
  class=$(cat "$d/class" 2>/dev/null)
  case $class in 0x03*) ;; *) continue ;; esac
  vendor=$(cat "$d/vendor"); device=$(cat "$d/device")
  driver="—"
  [ -e "$d/driver" ] && driver=$(basename "$(readlink "$d/driver")")
  hwmon=$(ls -d "$d"/hwmon/hwmon* 2>/dev/null | head -n 1)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$d" "${d##*/}" "${vendor#0x}" "${device#0x}" "$driver" \
    "$(cat "$d/boot_vga" 2>/dev/null || echo 0)" "${hwmon:--}"
done | LC_ALL=C gawk -F'\t' -v ids="$ids" '
  { rows[NR] = $0; want[$3] = 1; wantDev[$3 " " $4] = 1 }
  END {
    # pci.ids: "vvvv  Vendor" at column 0, "\tdddd  Device" under it.
    if (ids != "") {
      while ((getline line < ids) > 0) {
        if (line ~ /^[0-9a-f][0-9a-f][0-9a-f][0-9a-f]  /) {
          cur = substr(line, 1, 4)
          if (cur in want) vname[cur] = substr(line, 7)
        } else if ((cur in want) && line ~ /^\t[0-9a-f][0-9a-f][0-9a-f][0-9a-f]  /) {
          k = cur " " substr(line, 2, 4)
          if (k in wantDev) dname[k] = substr(line, 8)
        }
      }
      close(ids)
    }
    for (i = 1; i <= NR; i++) {
      split(rows[i], f, "\t")
      k = f[3] " " f[4]
      printf "%s\t%s\t%s\n", rows[i], (f[3] in vname) ? vname[f[3]] : f[3], (k in dname) ? dname[k] : f[4]
    }
  }'
