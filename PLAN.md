# PLAN

Finished plans are in the git history (`git log -p PLAN.md`): package source
(repos.conf), netboot docs consistency, netstick, network UKI below 80 MiB,
T450s findings with usb/network aligned, the identity made once with unattended
updates (83b7cc2), one `safespace` command, moving and clearing the identity, SHA-1
on the T450s, the identity through aSSH, the PIN-moved host key, the TPM2 binding,
the os-release name, firmware by package, the cleanup (one place for everything, 2731e8d).

## Still open from earlier plans

- **build.sh has no lock:** a second build started while one runs deletes the first one's
  `.parts-*` directory at its start (seen 2026-10-21: the first build failed). Proposal: `flock`
  on the output root.

- usb variant: boot the current build in QEMU (explicit `KernelInitrdModules=` list).
- `fluidsynth.service` (user unit from vlc-plugin-fluidsynth) fails without a
  SoundFont: mask it in the image? (proposal, not decided)
- netstick: QEMU boot of a netstick image not tested.

---

# PLAN: the machine's machine-id before the network

Status: **done 2026-10-27** (confirmed the same day: "go ahead with the reordering"):
tests/vm.sh run-20261027-161341, all 48 passed (`dhcp=machine` over the network with the
identity, `temporary` without).

The problem (the user, T450s over the network): the rootfs is fetched from another IP
address than the running system has. systemd-networkd's DHCP client identifier comes from
the machine-id; the initrd has none of its own (`/etc/machine-id` = `uninitialized`, a
temporary one per boot), and the machine's is released only after netroot fetched the root.

Releasing it needs nothing from the network (PCR 11 signed for enter-initrd, PCR 7, PCR 15
with the combination - chosen from the signed command line and the EFI variables). So:

1. **The combination chosen in a step of its own:** `safespace-select.service` (script
   `choose`: select_root) chooses and measures it, before the identity and both boot paths;
   usb-bootdev and netroot require it and take the chosen one (`select_chosen`: the name from
   /run/safespace/combination, its root hash from the signed command line) instead of choosing.
2. **The identity before the network:** safespace-identity.service after the choice and
   before `network-pre.target` (so before systemd-networkd and netroot), no longer after the
   boot paths. The released machine-id is written into the file itself (in place), into
   `/run/machine-id` and the initrd's `/etc/machine-id` (PID 1's bind mount of it), so the
   initrd's networkd - started after it - asks DHCP as the machine, and the root's PID 1
   takes it over as now. Not released (another combination, no identity): as now, the
   initrd's temporary one.
3. **Shown and tested:** netroot logs whether DHCP asks as the machine (the initrd's
   /etc/machine-id is the released one) or with a temporary machine-id; tests/vm.sh expects
   `dhcp=machine` for a network boot with its identity, `temporary` without.
   tests/run.sh: the unit order, the machine-id written in place, `choose` with only
   programs of the initrd. Docs: README (the boot order), NETBOOT.md.

## Tests

tests/run.sh after every step; the full tests/vm.sh once the user acknowledged the rework as complete (AGENTS.md); commit when all pass.

---

# PLAN: one configuration on the build host; no constant twice in the image

Status: **confirmed 2026-10-27** (the user: "go ahead with the plan"); one full tests/vm.sh at the end, for this and the DHCP order (the user).
**Done 2026-10-27**: tests/run.sh 296 passed, tests/vm.sh run-20261027-161341 all 48 passed
(build C: the identity under another policy). Found on the way: tests/vm.sh staged build B with release.sh without --push,
and release.sh pushed it to release.conf's RELEASE_TARGETS - a test build reached the real
server twice (runs 20261027-1413 and -1436). Now a build from --builds never goes to
RELEASE_TARGETS (release.sh, a test in tests/run.sh, SECURITY.md).

The problem (the user): choosing another PCR combination or another default key type for
aSSH means editing several files (both copies of the policy: assh.conf, the initrd's
`identity` for the machine-id), and the build host's settings are spread over six files
(`repos.conf`, `repos.local.conf`, `netboot.conf`, `release.conf`, `combinations.conf`,
`mkosi.local.conf`). In the image, the same constants (GUID, variable names, the CA's
variable, the credential name) are written into several scripts.

On the device nothing is configured: the image is signed and read-only. So the
configuration lives on the build host, and the build writes it into the image once.

## 1. `safespace.conf` and `safespace.local.conf`

- `safespace.conf` (tracked): every key with its default and its meaning, the one place
  to read what can be chosen. `safespace.local.conf` (gitignored, the host's choices): its
  keys win. Parsed, not sourced (as repos.conf today): only known keys, an unknown key is an
  error, no code runs.
- `build.sh --config FILE` adds a further layer on top (tests/vm.sh: its throwaway user,
  its combinations), instead of `--users` and `--combinations`.
- One parser, `lib/conf.sh`, for build.sh, release.sh, update-snapshot.sh and the tests.

| Key | Default | Today in |
|---|---|---|
| `COMBINATIONS` | `root=base containers=base,docker debug=base,debug` | combinations.conf |
| `USERS` | `users.conf` (a file: the ssh keys stay in their own, gitignored file) | `--users` |
| `SNAPSHOT`, `MIRROR` | `latest`, `https://ftp.fau.de/archlinux` (as repos.conf had) | repos.conf, repos.local.conf |
| `NETROOT_URL` | empty (sticks only) | netboot.conf, `--url` (the flag stays and wins) |
| `RELEASE_TARGETS` | empty | release.conf |
| `EROFS_WORKERS` | all CPUs | mkosi.local.conf, `--workers` (stays and wins) |
| `SBCTL_CONFIG` | the host's sbctl keys | mkosi.local.conf |
| `IDENTITY_SLOTS` | `0,2,7,15+11 7,15` (slots in order; `+11`: PCR 11 signed by the build) | assh.conf |
| `MACHINE_ID_PCRS` | `7,15+11` | identity (`--tpm2-pcrs=7+15`, `--tpm2-public-key-pcrs=11`) |
| `KEY_TYPES` | `rsa2048,p256` (the host key and the CA, first the TPM takes) | assh.conf (2 keys) |
| `PCR_BANK` | `auto` | assh.conf |

`mkosi.local.conf` stays for raw mkosi settings only. The removed files (`repos.conf`,
`netboot.conf`, `release.conf`, `combinations.conf`, their examples, tests/vm.combinations.conf)
go; a leftover gitignored one on the host (netboot.conf, release.conf, repos.local.conf)
stops build.sh with "moved into safespace.local.conf: KEY" - otherwise a URL would be
dropped without a word and a build would boot from sticks only.

## 2. The build checks the policy and writes it into the image

build.sh refuses a policy that would weaken the identity:
- PCR 15 (the combination, also the window) in every slot and in `MACHINE_ID_PCRS`: else an
  identity is no longer per combination, and a slot without the window would sign after it
  closed.
- PCR 7 (Secure Boot) in every slot and in `MACHINE_ID_PCRS`.
- Signed only PCR 11 (systemd-stub signs nothing else); PCRs 0-23 without 16 and 23.
- Key types: aSSH's (`rsa2048`, `p256`, ...); aSSH parses the generated assh.conf before
  the build goes on.

Generated by build.sh (lib/settings.sh), gitignored, into the root and the initrd alike
(as the assh binary today):
- `/etc/assh/assh.conf`: the fixed part (EFI variable, authority once, window, key ID, the
  agent's paths: a template in `lib/assh.conf.in`) and the chosen slots and key types.
  `mkosi.extra/etc/assh/assh.conf` is no longer tracked.
- `/usr/local/lib/safespace/settings` (shell variables, sourced): the constants - the
  vendor GUID, the variable names (`SafespaceSelect`, `SafespaceSelectOnce`,
  `SAFEmachineID`), the credential name, the CA's variable path (from the same value as
  `ASSH_CA`), the inventory app ID - and the machine-id's PCRs.

The image's scripts (`select`, `choose`, `identity`, `state.sh`, `safespace`) source
`settings` and keep no constant of their own. `safespace` prints the policy the image was
built with (`safespace identity`).

## 3. What a changed policy means

The machine-id's policy is in its credential, and the CA's slots were approved once, at the
creation. A build with other PCRs therefore applies to identities made after it: an
existing one keeps working as long as its own policy holds (the machine-id unseals; aSSH
certifies through the slots it approved) - slots that were never approved certify nothing,
the boot then shows a temporary key. A new identity under the new policy:
`safespace identity clear` and a reboot. build.sh says so when the policy differs from the
last build's (build.json records it).

## Tests

- tests/run.sh: the parser (defaults, local wins, `--config` on top, an unknown key, a
  leftover old file); every refused policy of 2.; the generated assh.conf parses in aSSH
  and holds the slots; `settings` holds every constant and no image script has one of its
  own (the "no copies" test, extended); the scripts' tests run against a generated
  `settings`.
- tests/vm.sh: with its own `--config` (the throwaway user, its combinations); one step
  built with another policy (e.g. one slot `0,7,15+11`, `KEY_TYPES=p256`): the identity is
  made with it (an ECDSA host key, certified through that slot) - run only after the user acknowledged the rework
  as complete (AGENTS.md).
- Docs: README (the configuration, a table of the keys), SECURITY.md (what the checks
  refuse and why), NETBOOT.md and AGENTS.md (the files that are gone).
