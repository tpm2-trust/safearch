AGENTS.md
    
## Engineering principles 
        
- **Future-ready by default.** Every change you implement must be modular,
  cleanly separated, and secure. Structure code so that future changes are easy
  to add without rewriting what already exists. Prefer clear interfaces,
  minimal coupling, and sensible defaults.
- **Security is not optional.** Validate inputs, handle errors explicitly, and
  never expose secrets or credentials in code, that is subject to be commited.
  If you find in existing project a security issue - bring this up with a WARNING!
- **Privacy is not optional.** Solutions we design and work on are subject
  to be published. Do not include there private data. If such is needed,
  always create a template configuration file, fill the private data into a
  gitignored file.
  
## Planning — mandatory before any programming task
            
When the user requests a programming task, **do not start coding immediately.**
        
1. Read the existing `PLAN.md` in the project root (if it exists).
2. Create or update `PLAN.md` to reflect the requested task. Include:
   - **Goal:** what the user asked for, in your own words.
   - **Steps:** a numbered breakdown of what you will implement.
   - **Open questions:** anything you need clarified before starting.
3. Present the plan to the user and wait for confirmation before writing code.
4. As you complete steps, update `PLAN.md` to mark them done
   (e.g. `- [x] step`).
5. Keep `PLAN.md` up to date when requirements change mid-conversation.

## Coding principles

- if you have to decide for a programming language at the beginning of a project
  tell the user about the decision for one language and give him possiblities to weigthen
  the use of a language by himself.
- Use if possible always the possibilities of a programming language it ships 
  with instead of using a library
- If you have use a library, use as less as possible, focus on broadly used libraries
  that cover a lot of requirements at once.

## Interfacing principles

- The user you are communicating with is an experienced Developer.
  Reduce your output to concrete formulations. If requested to explain something
  you can focus on technical in-depth explanations

## Testing
    
- We like solutions, that can be tested. Especially Integration Testing.
  However if the task is complex to simulate ask the user about the plan to 
  implement for testing specifically.
        
## Backwards compatibility
        
- **We are in Developer Mode.** Do not preserve backwards compatibility unless
  the user explicitly asks for it.
- However, if a change you are about to make **breaks existing functionality**,
  warn the user clearly before proceeding. Explain what will break and why.
        
## Diagrams         
                    
- When visualising architecture, flows, or relationships, use **Mermaid**
  diagrams (in Markdown fenced code blocks with `mermaid` as language).
- Place diagrams in `PLAN.md`, `README.md`, or inline in your response —
  wherever they add the most clarity.


## This project

safespace-arch: a read-only, Secure-Boot-signed Arch Linux image built with
mkosi 27: one build boots from a USB stick / SD card and over the network; it holds every
combination of package groups (`COMBINATIONS` in `safespace.conf`) as a chain of verified layers - each group built once (`lib/layers.sh`). README.md is
the user manual (read "Two roles" and "Deploy from scratch" first), NETBOOT.md
the network-boot reference, SECURITY.md the applied hardening. Arch Linux only, everywhere.

### Map

| Role | Files |
|---|---|
| build host (has the keys) | `build.sh` (entry point), `release.sh`, `fetch-images.sh`, `update-snapshot.sh`, `burn.sh`, `diagnose.sh`, `test-vm.sh`, `hwtest-image.sh` |
| image configuration | `mkosi.conf` (the image, both boot paths), `mkosi.profiles/{docker,xfce4-headless-vnc,debug}/` (groups), `mkosi.repart/`, `mkosi.extra/`, `mkosi.postinst`, `mkosi.finalize`, `mkosi.postoutput` |
| initrd | `mkosi.initrd.conf/`: `usb-bootdev` (layers from the stick) and `netroot` (layers over HTTP), chosen at boot by `LoaderDevicePartUUID`, both open and stack them with `stack` (no `root=`: the stack is `/sysroot`); `choose` (safespace-select.service, before both and the identity) decides the combination with `select` (sourced by all: its chain of layers); `identity` before the network |
| configuration | `safespace.conf` (every key, its default; this host's: `safespace.local.conf`), `lib/conf.sh` (parsed, not sourced), `lib/settings.sh` (the identity's policy checked, `assh.conf` from `lib/assh.conf.in` and the scripts' `settings` written into root and initrd: no constant twice in the image) |
| combinations, layers | `COMBINATIONS` (the first is the default), `lib/layers.sh` + `lib/layertree.py` (each group a layer, built once: trees, difference, checks, proof, images), `lib/compose.sh` (one UKI for all: layers and chains on its command line; `compose_check`), the initrd's `select` + `stack`, `mkosi.extra/usr/local/sbin/safespace select` |
| distribution server | `server/` (`setup.sh`, `safespace-netboot`, units, nginx site, `server.conf.example`) |
| shared shell code | `lib/repos.sh`, `lib/groups.sh`, `lib/keys.sh`, `lib/builds.sh` (the builds in `mkosi.output/combined_<version>/`: their parts, list, prune), `lib/stick.sh` (a stick assembled from the parts), `lib/verify.sh` (also installed on the servers; the release checks, a UKI's sections, the partition types and UUIDs of a stick: the one copy of each), `lib/assh.sh` (builds aSSH) |
| machine identity | `assh/` (submodule, [aSSH](assh/README.md), Go: the host key in the TPM, its CA; built by `lib/assh.sh` with the build host's Go, `GOWORK=off`, into `mkosi.extra/usr/bin/assh`; a pin, edited in the workspace's `../assh` and moved by `../pin assh`), `/etc/assh/assh.conf` (generated: `lib/settings.sh`), `assh-agent.service`, `safespace` (`identity`, `identity clear`, `update`, `issue`: the console before the login), `mkosi.extra/usr/local/lib/safespace/state.sh` (the identity's state, for the login and `safespace` alike), the initrd's `identity` (makes the machine-id and the CA at once; aSSH in the initrd); SECURITY.md "Machine identity" |
| tests | `tests/run.sh` (no root), `tests/vm.sh` (integration in QEMU), `tests/lib/` |
| per-host files (gitignored) | `safespace.local.conf` (the keys: `safespace.conf`), `users.conf`, `mkosi.local.conf` (raw mkosi only), `server/server.conf` (templates `*.example`) |

### Invariants — a change that breaks one of these needs the user's explicit OK

- **No private key in an image, a release or the repository.** Only certificates,
  signed `.auth` updates and the GUID are exported (`lib/keys.sh`);
  `mkosi.postoutput` enforces it.
- **Every image is signed**, and the UKI is signed by exactly the `db.pem` it
  ships (`mkosi.postoutput`).
- **A distribution server trusts only the pinned public `db.pem`** and never
  alters what it serves: it reports, the build host replaces. The upload account
  is confined by rrsync (write-only, no delete, share only).
- **`lockdown=integrity` on the signed command line** (`mkosi.postoutput` enforces it).
- **Root only through dm-verity** with the root hash from the signed command
  line; nothing on the boot medium is ever written; `/var` is RAM.
- **One build serves both boot paths** (stick and network), chosen by the initrd at boot;
  both open the layers the same way (dm-verity, signed root hash, `--panic-on-corruption`) and
  stack them at `/sysroot` the same way (`stack`: read-only, the settings' overlayfs options).
- **One release per server**, fixed file names; the initrd's reaction to a replaced release
  must not turn into a reboot loop.
- **Groups are the only difference between combinations;** a group is a layer, built once on
  exactly one layer below it; a combination is a chain of layers (base first), stacked
  read-only, never a free combination. A layer only adds: the build refuses one that changes
  a package below it, deletes a path of it or touches the kernel, and proves every stack equal
  to the combination built in full (`lib/layers.sh`, `lib/layertree.py`). Keep both - the
  proof is what makes a layer trustworthy, not the way it was made.
- **The composed UKI is checked** (`compose_check`): signer, `lockdown=integrity`, no
  `roothash=`/`root=`, every layer's hash and every combination's chain in order, signed
  expected PCRs.
- **A selection never supplies a root hash or a layer.** The EFI variables /
  `safespace.select=` only name a combination; its layers and their hashes come from the
  signed command line, and without `safespace.root.<name>=` nothing is opened.
- **EFI variables only through aSSH.** The selection's, the machine-id's and the CA's
  variables are read, written and removed with `assh efivar` (and `assh ca`) - in the
  root (`safespace`) and in the initrd (`select`, `identity`) - never by writing or
  `rm`-ing efivarfs in a script: aSSH writes a variable in place, never removes it
  first, lifts efivarfs' immutable mark and puts it back, and treats none there as
  no error (aSSH's `persist`). Tests point it at a directory (`SAFESPACE_ASSH`,
  `ASSH_EFIVARS`).
- **Builds are kept and shipped as parts** (UKI, the layers' images, verity trees and root
  hashes, systemd-boot, partition table); no disk image is stored or shipped.

### Working on it

- Run `tests/run.sh` after every change (no root, ~15 s). Add a test for new
  behaviour there: fixtures with throwaway keys are in `tests/lib/fixtures.sh`.
  A SKIP is not a pass: say which tool was missing.
- After a change to the image, the initrd, the build, the release or the server, the
  integration test `tests/vm.sh` is due - but only once the user has acknowledged that the
  rework is complete. Every run, a single step too, builds every combination, and a full
  one boots them all: it takes a long while, so it is not run after each step or fix.
  Until then `tests/run.sh`; then say the rework is done and ask before running it (also
  again after a fix for a failed run). `tests/vm.sh` (test build with a throwaway user, release into its own
  share, server check, QEMU boots from a stick and over the network, sealing, Secure Boot,
  every combination booted through the selection; the boots run side by side, `--jobs N`;
  the base and one mkosi run per further layer, so the build's duration grows with the layers). It needs the build host's sudo rule for `build.sh`; if a prerequisite is
  missing it says which: hand that to the user instead of working around it. Never release
  a test build (`mkosi.test/vm/builds/`) to a real server: it carries the test key.
- Not testable without root or hardware — say so and hand it to the user with
  the exact commands: a real `build.sh` run, `server/setup.sh`, the units under
  systemd, booting in QEMU (`test-vm.sh`) or on a machine, YubiKey keys.
- Script conventions: bash with `set -Eeuo pipefail` (the initrd scripts are
  POSIX sh); the usage text is the comment header (printed by `-h`); `log`/`die`
  helpers; validate every input that ends up in a path, a URL or a config file;
  comments say why, not what.
- Docs: every user-visible change goes into README.md (and NETBOOT.md if it
  concerns network boot, SECURITY.md if it changes a security measure) in the same
  change; keep the anchors working.
- PLAN.md holds the current plan; finished plans stay in git history.
