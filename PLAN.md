# PLAN

Finished plans are in the git history (`git log -p PLAN.md`): package source
(repos.conf), netboot docs consistency, netstick, network UKI below 80 MiB,
T450s findings with usb/network aligned, the identity made once with unattended
updates (83b7cc2), one `safespace` command, moving and clearing the identity, SHA-1
on the T450s, the identity through aSSH, the PIN-moved host key, the TPM2 binding,
the os-release name, firmware by package, the cleanup (one place for everything, 2731e8d), the machine-id before the network and one
configuration on the build host (2f20ca7).

## Still open from earlier plans

- **build.sh has no lock:** a second build started while one runs deletes the first one's
  `.parts-*` directory at its start (seen 2026-10-21: the first build failed). Proposal: `flock`
  on the output root.

- usb variant: boot the current build in QEMU (explicit `KernelInitrdModules=` list).
- `fluidsynth.service` (user unit from vlc-plugin-fluidsynth) fails without a
  SoundFont: mask it in the image? (proposal, not decided)
- netstick: QEMU boot of a netstick image not tested.

---

# PLAN: aSSH at 93d79df - the window in the CA's policy

Status: **proposed** (2026-10-30), waiting for confirmation.

## Goal

Move `assh/` to aSSH 93d79df (its security fixes P1, assh/PLAN.md) and adapt safearch.
What changes for safearch:

- **The window is the CA's own.** The CA's policy reads an NV index W (0x01802915) that the
  agent read-locks after the host key; no approval can leave it out. `ASSH_CA_WINDOW` is
  gone; PCR 15 stays in every slot (the combination) and can still be extended at the close
  (`ASSH_CLOSE_PCR=15`).
- **Fail-closed.** The agent closes the window on every way out; `assh close` is meant to
  run after the unit (`ExecStopPost=`).
- **A new CA's window is closed in the boot that creates it** (aSSH's default): the
  initrd's `ca create --authority-once` at the first sealed boot gives a **temporary key in
  that boot**; the machine is certified from its second boot on (open question 1).
- `ca remove` removes W too (identity clear, the initrd's all-or-nothing).
- The CA file is format 4: an existing identity's CA (SAFEasshCA of format 3) is not read -
  `safespace identity clear` and a new identity, a new `@cert-authority` line.

## Steps

- [ ] 1. Pin: `safearch/assh` to 93d79df (staged, as `../pin assh` does for this submodule).
- [ ] 2. `lib/assh.conf.in`: `ASSH_CA_WINDOW` out, `ASSH_CLOSE_PCR=@PCR@` in (PCR 15 still
       extended by the agent, as today); comments say the window is the CA's index.
- [ ] 3. `lib/settings.sh`: the refusal of a slot without PCR 15 stays (per combination),
       its reason without "the window".
- [ ] 4. `assh-agent.service`: `ExecStopPost=/usr/bin/assh close --config /etc/assh/assh.conf`;
       comments.
- [ ] 5. The initrd's `identity`: comments (the CA signs from the next boot on, unless open
       question 1 says otherwise).
- [ ] 6. `tests/run.sh`: the assh.conf check (`ASSH_CLOSE_PCR=15`, no `ASSH_CA_WINDOW`),
       the policy refusal text; `tests/vm.sh`'s expectations: the first sealed boot
       temporary and the second certified, an agent restart "window is closed" instead of
       "PCR 15 not as approved" (vm.sh is run later).
- [ ] 7. README ("Machine identity", the tests table), SECURITY.md (the identity's
       sequence, "The window", the policy row, the test row).
- [ ] 8. `tests/run.sh`.

## What breaks

- Existing identities: their CA (format 3) is not read; the agent serves a temporary key
  until `safespace identity clear` and a new identity (new `@cert-authority` line).
- The first sealed boot no longer certifies (unless question 1 decides otherwise).

## Open questions

1. The first sealed boot: accept a temporary key there (aSSH's default: no CA signs in the
   boot that made it), or add an opt-in to aSSH that leaves the creating boot's window open
   (`ca create --window-open`, `ASSH_WINDOW_OPEN`) for safearch's initrd, where only the
   initrd and the early root run before the agent closes it?
2. Keep the agent extending PCR 15 at the close (`ASSH_CLOSE_PCR=15`, as today), or drop it
   now that W closes the CA? Nothing in the root binds to PCR 15 after the identity's
   "sealed" as far as I see; keeping it changes nothing.

---

# PLAN: each layer built once - the roots as verified layers, stacked by the initrd

Status: **confirmed 2026-10-27** (the user: "write it. clean up old caches / produced builds
and then start implementing"). The full tests/vm.sh once the user acknowledged the rework as
complete (AGENTS.md).

**Done 2026-10-27**: tests/vm.sh run-20261027-191547, all 48 passed (every boot stacked its
combination's layers - base alone as erofs, base+docker as read-only overlayfs - every layer
verified, the identity certified, the update and the policy build); tests/run.sh 335 passed.
Found by the first boots: without root= nothing creates /sysroot in the initrd (stack does);
usb-bootdev's messages now reach the console too. A real build
(combined_20261027-1754) went through every check and the proof, and release.sh's checks
pass on it. Measured (step 1): base tree 83 s, base image 99 s, docker tree 28 s + layer 26 s,
debug tree 29 s + layer 15 s - the whole build 4 min 50 s (before: 6-12 min); the build
584 MiB instead of 1.4 GiB, the layers 392 + 97 + 5 MiB instead of roots of 392 + 489 + 397
MiB. Found by the checks on the way: the base's tree must be built with the image's boot
steps (kernel-install's entry-token, the signed systemd-boot), or every layer lacks them.

Today every combination is a root of its own: base 392 MiB is in root (392), containers
(489) and debug (397) - 1278 MiB per release for about 500 MiB of different content, and
every combination runs the whole mkosi pipeline. A group becomes a **layer**: built once,
shipped once, stacked at boot.

The experiment (2026-10-27, unprivileged, not in the repository) showed:
- mkosi's own `Overlay=` cannot make our layers: it drops every path the base has
  (/etc/group, /etc/gshadow, ld.so.cache, fstab, the combination file) - made for sysexts,
  which may only add.
- What works: the combination built in full on a copy of the base (`BaseTrees=`, 31 s instead
  of 51 s), the layer = every path that is new or differs (type, mode, owner, content,
  xattrs: 168 paths for docker), and base + layer stacked read-only equal to the full tree:
  24847 entries each, **0 differences**. No base package changed, nothing deleted.
- erofs (zstd 6): base 389 MiB, docker layer 96 MiB, the full root 486 MiB; the layer
  verifies against its own root hash.

## Rules

- **A layer is a group, on exactly one parent**: a combination is a chain - base first,
  then its groups in the order COMBINATIONS names them; a group that lies on different
  parents in two combinations is refused (one layer per group, built once). Layers only
  stack, never combine freely.
- **A layer only adds**: the build stops when a layer changes a base package (manifests),
  deletes a path of the layer below, or touches the kernel (/usr/lib/modules, /boot, /efi).
- **Proved at every build**: the layers stacked as the initrd stacks them equal the
  combination built in full, file for file (type, mode, owner, content, xattrs).
- **dm-verity as today, per layer**: each layer an erofs image with its hash tree; its root
  hash on the signed command line. Opened by the initrd with `--panic-on-corruption`, stacked
  read-only: overlayfs without an upper layer, `ro,metacopy=off,redirect_dir=off,index=off`
  (one layer: the erofs device itself). Nothing writable, nothing from outside the signed
  images.
- **The identity does not change**: PCR 15 measures the combination's name before anything is
  opened; the signed command line fixes which layers that name means.

## Steps

1. **Measure** where a build's time goes (build.sh logs every step's duration), before and
   after.
2. **Build** (build.sh, lib/layers.sh): the base as a tree (`Format=directory`, the package
   database kept), then the base image (`BaseTrees=` that tree, `Format=disk`: UKI, initrd,
   systemd-boot, the base's erofs and verity as today); every further layer as a tree on its
   parent's tree (`BaseTrees=`, its group's profile); /var moved into /usr/share/factory after
   (one function for mkosi.finalize and build.sh); the layer = the difference to the tree
   below (the base: extracted from its image, exactly what the machine gets); the checks and
   the proof above; erofs (zstd 6) and dm-verity per layer. mkosi.postinst runs again on a
   copy (the users exist: only the group memberships; the docker fstab line once).
3. **Compose** (lib/compose.sh): the command line `safespace.layer.<layer>=<hash>` per layer and
   `safespace.root.<combination>=<layer>,<layer>...` (bottom first); no root=/rootfstype=
   (mkosi.conf), `systemd.gpt_auto=0` (+ rd.); the files root-<layer>.img/.verity,
   roothash-<layer>, manifest-<combination>.json; the stick layout one pair per layer;
   compose_check per layer.
4. **Initrd**: select reads the chain and the layers' hashes (an unknown layer stops the boot);
   usb-bootdev and netroot open every layer of the chosen combination (netroot downloads only
   those) and mount the stack at /sysroot themselves, before systemd-volatile-root and
   initrd-root-fs.target.
5. **Release, server, stick**: release.sh, lib/verify.sh (every layer against its signed
   hash; COMBINATIONS and LAYERS in the release file), server/safespace-netboot, burn.sh,
   diagnose.sh, lib/stick.sh, test-vm.sh, hwtest-image.sh.
6. **Tests and docs**: tests/run.sh (fixtures as layered builds; chains, refused chains, the
   diff, the proof, deletions refused, the initrd's stacking), tests/vm.sh (root=overlay for a
   layered combination, erofs for base alone; sizes); README, SECURITY.md, NETBOOT.md,
   AGENTS.md.
