# Packaging pipeline — measured facts, deviations, and how to verify

Owner: `build.sh` + `tests/**` (build/test harness scope).
Companion of `docs/INTEGRATION-CONTRACT.md`; this file records what was
actually measured on this device while building the pipeline, plus the
contract deviations that could not be avoided.

Device: fnOS 1.2.1102, x86_64, Debian 12 userspace, fnpack 1.2.4,
running as the non-root user `fn-deepseek-harness` (uid 937).

---

## 1. Quick start

```bash
cd v2raya-fnos
bash build.sh                # -> dist/v2raya_2.5.16-1_x86.fpk
bash tests/run-all.sh        # lint + build + fpk-structure + smoke + gateway-sim
```

Individual stages:

```bash
bash tests/lint.sh                       # static checks (no build needed)
bash build.sh                            # produce the .fpk
bash tests/fpk-structure.sh [file.fpk]   # structure assertions (newest dist/*.fpk by default)
bash tests/smoke.sh                      # simulated install: start/probe/status/stop
bash tests/gateway-sim.sh                # prefix-preserving gateway reproduction
```

Exit codes for every test script: `0` pass, `1` failure, `77` **BLOCKED**
(a prerequisite artefact such as `cmd/` or a `.fpk` is missing — explicitly
*not* a pass).

---

## 2. Deviations from the contract (both forced by measured behaviour)

### 2.1 `.fpk` is a **gzip-compressed** tar, not a plain tar — no action needed

Contract §1 says "外层 `.fpk` 是 **tar**". On this device `file` reports
`gzip compressed data`. `tar -tf/-xf` handles both transparently, so
`build.sh` and `tests/fpk-structure.sh` accept either and print which one they
found. **This is a documentation nit, not a functional problem.**

### 2.2 `version = 2.5.16.<rev>` is NOT packable — build.sh auto-normalises

Contract §3 specifies `version = 2.5.16.<fpk-rev>` (four numeric parts).
fnpack 1.2.4 rejects that outright. Probed directly:

| manifest version | fnpack result |
| --- | --- |
| `2.5.16.1`   | **rejected**: `Invalid version "2.5.16.1". Expected format: x.y.z[-r]` |
| `2.5.16-r1`  | **rejected** (non-numeric revision) |
| `2.5.16`     | accepted |
| `2.5.16-1`   | accepted |
| `2.5.16-0`   | accepted |
| `2.5.16.1.2` | rejected |

Every app installed on this box follows `x.y.z` or `x.y.z-<tag>` (e.g.
`OpenList 4.2.9`, `EasyTier-Web 2.6.4-v2`).

`build.sh` therefore keeps the contract's *intent* (upstream `x.y.z` + an
integer fpk revision) and writes it in fnpack's grammar:
`2.5.16.1` → **`2.5.16-1`**, giving
`dist/v2raya_2.5.16-1_x86.fpk`.

The rewrite is applied to a **staged copy only** — the repository's `manifest`
is never modified, because it belongs to another owner. The build prints
`version normalised for fnpack: 2.5.16.1 -> 2.5.16-1` so this is never silent.

> **Recommendation for the manifest owner:** change
> `manifest.version` to `2.5.16-1` so the repository and the artifact agree
> literally. Until then `build.sh` normalises it on the fly and both work.

---

## 3. fnpack 1.2.4 traps that build.sh defends against

### 3.1 `fnpack build` exits **0 even when packing fails**

Measured on every failure mode tried (missing `ICON_256.PNG`, missing
`manifest`, missing `cmd/main`, missing `app/ui/config`, invalid JSON in
`config/privilege`, missing wizard, bad icon dimensions): each printed
`Packing failed. …` and returned **exit status 0**.

Consequences, all handled in `build.sh`:

* the exit code is never trusted;
* stdout is scanned for `Packing failed` / `Packing successfully`;
* the produced file must exist before anything is published.

### 3.2 `-d` only sets the **source**; output always goes to the *current* directory

`fnpack build -d /tmp/stage` run from the repo root still wrote `v2raya.fpk`
into the repo root. `build.sh` therefore runs fnpack with `cd "$WORKDIR"` so a
stray `.fpk` can never land in the source tree.

### 3.3 Source directories with mode `000` break packing

`app`, `app/assets`, `app/ui`, `app/ui/images`, `app/server` are `d---------`
(mode 000) on disk; access is granted by a btrfs ACL, not by the mode bits.
fnpack preserves the literal mode when copying, creates the destination with
mode `000`, then cannot write into it:

```
Packing failed. Copy pack <repo> to tmp dir /tmp/fnpack.N error :
mkdir /tmp/fnpack.N/app/assets: permission denied
```

`build.sh` always packs a **staged, mode-normalised copy** (dirs 755, files
644, exec bits restored for the two binaries and all `cmd/*`). The resulting
archive is identical to what a correctly-moded tree produces (verified: entries
inside `app.tgz` are 755).

### 3.4 What fnpack *does* validate

* required files: `manifest`, `cmd/main`, `ICON.PNG`, `ICON_256.PNG`, `app/ui/config`
* `config/privilege` / `config/resource` / `app/ui/config` parse as JSON
* `wizard/*` parse as JSON **and** match an expected schema
* `manifest` required fields (`source` was demanded in testing)
* `desktop_applaunchname` must name an entry in `app/ui/config`
* version grammar `x.y.z[-r]`
* it does **not** validate icon dimensions, and does **not** check the exec bit
  of `cmd/*` (but it does preserve whatever bit is set)

### 3.5 Exec bits are preserved through both layers

Verified round-trip: `chmod 755` on `app/server/*` and `cmd/main` → the outer
tar shows `-rwxr-xr-x` → extracting `app.tgz` yields mode 755 on disk → the
extracted `v2raya` runs and prints `2.5.16`. `build.sh` asserts this on the
artifact before publishing (a 644 `v2raya` cannot start after install).

---

## 4. v2rayA runtime facts used by the tests (measured)

Started exactly as `cmd/main` does, on a unix socket with `--baseurl /app/v2raya`:

| request (over `--unix-socket`) | status |
| --- | --- |
| `/app/v2raya/api/version` | **200**, JSON with `hasAccounts` (bool) |
| `/app/v2raya/` | **200** |
| `/app/v2raya` (no trailing slash) | **301** |
| `/` | **404** |

* SIGTERM shutdown measured at **~44 ms**.
* After SIGTERM the **socket file is left behind** (stale). `cmd/main stop`
  unlinks it; the smoke test reports a leftover socket as a note, not a hard
  failure, because it cannot block a restart (`start` removes it first).
* Running as the package user, `/api/version` reports `lite=1`, `isRoot=false`.

### Test scoping note (important on a shared box)

Other sessions run their own `v2raya` (observed:
`./appserver/v2raya --socket /tmp/vtest-exp/app.sock`). A naive
`pgrep -x v2raya` survivor check produced a **false failure** during
development. The tests therefore:

1. snapshot v2raya pids at start (`BASELINE_PIDS`),
2. attribute a survivor only if the pid is **new** *and* its `/proc/<pid>/cmdline`
   references **this test's scratch tree**,
3. ignore and merely report foreign v2raya processes.

---

## 5. Files

| path | purpose |
| --- | --- |
| `build.sh` | preflight → validate → pack → verify → publish `dist/v2raya_<ver>_x86.fpk` |
| `tests/lib-test.sh` | shared PASS/FAIL accounting, cleanup trap, PNG/HTTP probes |
| `tests/lint.sh` | JSON, manifest, `cmd/*`, icons, `/vol` paths, `TRIM_` namespace, `ui/config` |
| `tests/smoke.sh` | simulated install: start, api/version, UI, status, stop, survivors, idempotency |
| `tests/gateway-sim.sh` | TCP→unix proxy that preserves the full path; proves `/app/v2raya` survives the hop |
| `tests/fpk-structure.sh` | artifact structure, embedded manifest (appname/platform/checksum), exec bits |
| `tests/run-all.sh` | runs every stage in order, prints one consolidated verdict |

`build.sh` options: `--help`, `--version-suffix N`, `--keep`, `--verbose`.
Environment: `FN_PACK_BIN` overrides the packer path.

---

## 6. Guarantees build.sh enforces before publishing

* stale `dist/*.fpk` and `./<appname>.fpk` are removed **first**, so a failed
  build never leaves a misleading old artifact behind
* `fnpack` present and identified by version
* `app/server/v2raya`, `app/server/v2raya_core`: present, executable, and
  actually run (`--version` non-empty)
* `geoip.dat` / `geosite.dat` ≥ 1 MiB (a truncated file makes v2rayA download
  on first start, which hangs on restricted networks)
* `ICON.PNG` 64×64, `ICON_256.PNG` 256×256, both ≤ 1024 KiB, plus
  `app/ui/images/icon_{64,256}.png` at matching sizes
* `manifest` carries all 15 required keys, and **no** `service_port` /
  `install_dep_apps`
* all JSON parses; all nine `cmd/*` exist, are executable, have a shebang and
  pass `bash -n`
* no hardcoded `/vol{n}` in executed `cmd/` code (comment-only mentions are
  tolerated and reported)
* no custom `TRIM_`-prefixed variables in `wizard/` (allowlist = the 41 system
  names inventoried from `/var/apps/*`)
* `app/ui/config` has no `{placeholder}` tokens (only the legal `{0}` icon
  token) and declares the gateway entry from contract §4
* the produced archive really contains everything and preserves exec bits
* build is non-interactive, offline, secret-free, and repeatable

---

## 7. Last full-suite result (real, observed)

```
STAGE            RESULT     TIME
lint             PASS       0s      (81 assertions: passed=81 failed=0 blocked=0)
build            PASS       7s
fpk-structure    PASS       2s      (passed=48 failed=0 blocked=0)
smoke            PASS       6s      (passed=25 failed=0 blocked=0)
gateway-sim      PASS       1s      (passed=15 failed=0 blocked=0)
OVERALL: PASS
```

Additionally verified by hand: the payload extracted from the produced `.fpk`
was installed into a scratch tree, and `cmd/main start|status|stop`, plus all
eight install/upgrade/config/uninstall callbacks, exited 0 — with
`/app/v2raya/api/version` returning HTTP 200 and `cmd/main status` returning 3
after stop.
