# procs.awk - one sample of the process table for the sysmon panel (gawk).
#
# The Luau side has a ~25ms CPU budget per callback, so every expensive step
# lives here: walking /proc, CPU deltas, filtering, sorting and truncating to
# `limit` rows. Luau only splits the few tab-separated lines this prints.
#
# Inputs:  stdin: "pid uid" lines from find. Users come from `getent passwd`
#          (covers systemd dynamic users too); unresolvable uids - typically
#          container users - show as "uid N".
# Vars:    state  - snapshot file of the previous sample (pid starttime ticks)
#          limit  - max rows printed
#          sort   - cpu | mem | name | user | pid order - asc | desc
#          filter - lowercase substring matched against name, user, pid, cmdline
#          mineuid - only this uid when non-empty
#          scale  - machine (sum of all rows = total CPU%) | core (100% = one core)
#          kthreads - 1 to include kernel threads
#          page   - page size in bytes
#
# Output:  "#\tprocs\tthreads\trunning\tmatched\tncpu"
#          then per row: pid ppid user state cpu memKB threads comm cmdline (tab-separated)

function readcmd(pid,    f, rs, c, part) {
  f = "/proc/" pid "/cmdline"
  rs = RS
  RS = "\0"
  c = ""
  while ((getline part < f) > 0)
    c = c (c == "" ? "" : " ") part
  close(f)
  RS = rs
  gsub(/[\t\n\r]/, " ", c)
  return c
}

BEGIN {
  while (("getent passwd" | getline line) > 0) {
    split(line, f, ":")
    if (!(f[3] in users)) users[f[3]] = f[1]
  }
  close("getent passwd")

  total = 0
  ncpu = 0
  while ((getline line < "/proc/stat") > 0) {
    if (line ~ /^cpu /) {
      # user nice system idle iowait irq softirq steal (guest is already in user)
      n = split(line, f, " ")
      for (i = 2; i <= 9 && i <= n; i++) total += f[i]
    } else if (line ~ /^cpu[0-9]/) {
      ncpu++
    }
  }
  close("/proc/stat")
  if (ncpu < 1) ncpu = 1

  prevTotal = 0
  if (state != "") {
    while ((getline line < state) > 0) {
      split(line, f, " ")
      if (f[1] == "T") prevTotal = f[2] + 0
      else { prevStart[f[1]] = f[2]; prevTicks[f[1]] = f[3] + 0 }
    }
    close(state)
  }
  dtotal = total - prevTotal
  haveDelta = (prevTotal > 0 && dtotal > 0)
  mult = (scale == "core") ? ncpu : 1
}

{
  split($0, f, " ")
  uidOf[f[1]] = f[2]
  pids[++npids] = f[1]
}

END {
  snap = "T " total "\n"
  nprocs = 0; nthreads = 0; nrun = 0; matched = 0

  for (k = 1; k <= npids; k++) {
    pid = pids[k]
    fn = "/proc/" pid "/stat"
    ok = (getline line < fn)
    close(fn)
    if (ok <= 0) continue # exited between find and here

    # comm may contain spaces and parens: it ends at the LAST ')'
    lp = index(line, "(")
    match(line, /.*\)/)
    rp = RLENGTH
    comm = substr(line, lp + 1, rp - lp - 1)
    split(substr(line, rp + 2), s, " ") # s[i] is stat field i+2
    st = s[1]; ppid = s[2]; flags = s[7]
    ticks = s[12] + s[13]; thr = s[18]; start = s[20]; rss = s[22]

    snap = snap pid " " start " " ticks "\n"

    if (!kthreads && and(flags, 2097152)) continue # PF_KTHREAD
    nprocs++
    nthreads += thr
    if (st == "R") nrun++
    if (mineuid != "" && uidOf[pid] != mineuid) continue

    uname = (uidOf[pid] in users) ? users[uidOf[pid]] : "uid " uidOf[pid]

    if (filter != "") {
      if (!index(tolower(comm), filter) && !index(tolower(uname), filter) && index(pid, filter) != 1) {
        c = readcmd(pid)
        if (!index(tolower(c), filter)) continue
        cmdOf[pid] = c
      }
    }
    matched++

    cpu = 0
    if (haveDelta) {
      # A pid missing from the last snapshot (or reused: other starttime) was born
      # during the interval, so all of its ticks belong to it.
      d = (pid in prevStart && prevStart[pid] == start) ? ticks - prevTicks[pid] : ticks
      cpu = d / dtotal * 100 * mult
      if (cpu < 0) cpu = 0
    }
    cpu = int(cpu * 10 + 0.5) / 10
    mem = int(rss * page / 1024)

    C[pid] = cpu; M[pid] = mem; N[pid] = comm; S[pid] = st
    P[pid] = ppid; T[pid] = thr; U[pid] = uname

    # Tie-breakers keep rows from shuffling every tick when many sit at 0.0%.
    if (sort == "mem") key[pid] = mem * 1e7 + pid # pid < 2^22, keeps 0 KiB kthreads ordered
    else if (sort == "name") key[pid] = tolower(comm) sprintf(" %010d", pid)
    else if (sort == "user") key[pid] = tolower(uname) sprintf(" %010d", pid)
    else if (sort == "pid") key[pid] = pid + 0
    else key[pid] = cpu * 10 * 1e11 + mem
  }

  if (state != "") {
    printf "%s", snap > state
    close(state)
  }

  printf "#\t%d\t%d\t%d\t%d\t%d\n", nprocs, nthreads, nrun, matched, ncpu

  kind = (sort == "name" || sort == "user") ? "str" : "num"
  PROCINFO["sorted_in"] = "@val_" kind "_" (order == "asc" ? "asc" : "desc")
  shown = 0
  for (pid in key) {
    if (shown >= limit) break
    shown++
    c = (pid in cmdOf) ? cmdOf[pid] : readcmd(pid)
    if (c == "") c = "[" N[pid] "]"
    if (length(c) > 400) c = substr(c, 1, 400) "…"
    gsub(/\t/, " ", N[pid])
    printf "%s\t%s\t%s\t%s\t%.1f\t%d\t%d\t%s\t%s\n", pid, P[pid], U[pid], S[pid], C[pid], M[pid], T[pid], N[pid], c
  }
}
