# PLAN

Finished plans are in the git history (`git log -p PLAN.md`): package source
(repos.conf), netboot docs consistency, netstick, network UKI below 80 MiB,
T450s findings with usb/network aligned, the identity made once with unattended
updates (83b7cc2), one `safespace` command, moving and clearing the identity, SHA-1
on the T450s, the identity through aSSH, the PIN-moved host key, the TPM2 binding,
the os-release name, firmware by package.

## Still open from earlier plans

- **build.sh has no lock:** a second build started while one runs deletes the first one's
  `.parts-*` directory at its start (seen 2026-10-21: the first build failed). Proposal: `flock`
  on the output root.

- usb variant: boot the current build in QEMU (explicit `KernelInitrdModules=` list).
- `fluidsynth.service` (user unit from vlc-plugin-fluidsynth) fails without a
  SoundFont: mask it in the image? (proposal, not decided)
- netstick: QEMU boot of a netstick image not tested.

---

# PLAN: cleanup - one place for everything, nothing twice

Status: **done 2026-10-27** (confirmed the same day, steps 9 to 12 added at the user's
request): tests/run.sh 233 passed, `tests/vm.sh` run-20261027-143631 all 46 passed. Behaviour stays as it is (the
user: "behaviour is correct and fine"); only the code gets smaller. Rule: a manual command
and the automatic path run the same code.

aSSH (submodule `assh/`, done beside this plan, tests and tpm2-kira green): `ca slot` and
`ca sync` are gone - every command, `agent` at its start, takes assh.conf's slots as they
are; one CA key creation for every authority, one approval scan (`ca show` now counts the
build's PCR 11 signature), one ending for every host-key path (it also closes the window
alike on every path), PCR selections, number lists and signatures made in one place each.
safearch uses none of what went: no change here but the submodule.

## Steps

1. **PLAN.md, PLAN-TPM2-BINDING.md:** finished and superseded plans out (git keeps them):
   PLAN.md keeps "still open" and this plan; PLAN-TPM2-BINDING.md goes. -2,100 lines.
2. **Stale words and dead code** (no behaviour): `arg()` in usb-bootdev; `STICK_ROOT`,
   `STICK_VERITY` in lib/stick.sh; test-vm.sh's hint `build.sh network --url` (no such
   argument) and "usb build"/"network variant"/"usb variant" (test-vm.sh, netroot,
   NETBOOT.md); hints for builds "from before ..." (release.sh, diagnose.sh: no backwards
   compatibility); the old identity words (safespace-identity.service "slots or assignment",
   tests/vm.combinations.conf "until it moves", SECURITY.md's "PIN-approved slot", vm.sh's
   probe comment, run.sh's `slot()` helper name and the `safespace-ssh-host-key` credential
   name, run.sh's check that `safespace` seals - it no longer does); the orphan comment in
   lib/builds.sh and the empty `# --- units` header in tests/run.sh; the login's "approved
   firmware" -> "firmware as at the creation" (as `safespace identity` says).
3. **The identity state, once:** `/usr/local/lib/safespace/state.sh` (sourced): the EFI
   paths and GUIDs, `var_byte`, the state (green/purple/noidentity/unsealed/temporary/
   throwaway, from /run/assh/status and the variables) and its colour. The login
   (profile.d) and `safespace` (overview, `identity`) source it, so both decide alike;
   the login maps state to colour once. The initrd keeps its own copies (another file
   system); tests/run.sh checks the constants match.
4. **The SHA-1 gate through aSSH:** the initrd's `identity` asks `assh tpm sha1`
   (`bank auto: sha256|sha1|none`) instead of parsing `tpm2 nvreadpublic`; aSSH's check is
   the stricter one and the one the agent uses. Then `tpm2-tools` leaves the initrd
   (~1.5 MiB of the UKI; it stays in the debug group), with `SAFESPACE_TPM2`,
   `SAFESPACE_TPM_SYSFS` and run.sh's tpm2 stub; the assh stub answers `tpm sha1`.
   `identity` also drops `--pcr-key` and `SAFESPACE_PCRKEY` (assh.conf's `ASSH_PCR_KEY`
   names the same file).
5. **Release files, once:** `builds_sign_release DIR` in lib/builds.sh (build.sh and the
   test fixture call it); burn.sh uses lib/verify.sh's `release_get` instead of its copy;
   `builds_combo_names DIR` for the three `combinations | tr | cut | paste` pipelines
   (builds.sh, release.sh, burn.sh).
6. **The partition layout, once:** the GPT type GUIDs, the root-hash-to-UUID step and one
   `sfdisk` dump parser (`layout_part`) in lib/verify.sh, used by compose, builds, verify,
   stick, test-vm.sh, diagnose.sh and the fixtures (today 9 copies of the GUIDs, 4 of the
   UUID step, 5 parsers); diagnose.sh sources lib/verify.sh (`uki_cmdline`, the
   combinations check it copies); `uki_section` and `uki_cmdline` become one.
7. **tests/vm.sh:** one `fw_var_set` for the three firmware-variable writes, `ID_GUID` ->
   `SELECT_GUID`; the probe reads the slot from /run/assh/status, as the login does.
8. **The submodule** to the cleaned aSSH; README/SECURITY/AGENTS where they name what
   changed.

9. **`select` asks about the identity:** changing to another combination than the booted
   one, with an identity on the machine, asks on a terminal "clear the identity too?"
   (default no: the identity stays with its combination, as now). Yes runs the same code as
   `identity clear` (no second question). Without a terminal nothing is cleared; flags
   `--clear-identity` / `--keep-identity` answer it for scripts (`--yes` does not: clearing
   is never implied).
10. **The status before the login:** the console shows `safespace <build> <combination>
    <kernel>` (/etc/issue) and below it the whole `safespace` overview, written at boot to
    `/run/issue.d/50-safespace.issue` by `safespace-issue.service` (after assh-agent; then
    `agetty --reload`), the same code as `safespace` (escaped for agetty). The overview gets
    the host key in full - the line ssh shows to whoever connects without the CA line - as
    `host key: <type> <base64>` beside its fingerprint.

11. **Docker Compose** (the user, the same day): the `docker` group gets the `docker-compose`
    package; tests/vm.sh checks `docker compose` exactly where `docker` is.
12. **The overview in colours** (the user, the same day): on a terminal and on the console,
    this boot and its host key in the identity's colour (state.sh's), the other lines green,
    yellow or red; `NO_COLOR` switches them off. The overview runs where the firmware has no
    Secure Boot variables and where the CA does not load (it shows aSSH's error).

## Tests

tests/run.sh after every step; `tests/vm.sh identity` after 3, 4, 7, 9 and 10 (the login
states, the SHA-1 step, the initrd, the question, the console); one full `tests/vm.sh` at the end. Commits when the user asks.
