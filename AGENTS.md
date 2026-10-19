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
mkosi 27, in two variants (`usb`, `network`) and package groups. README.md is
the user manual (read "Two roles" and "Deploy from scratch" first), NETBOOT.md
the network-boot reference. Arch Linux only, everywhere.

### Map

| Role | Files |
|---|---|
| build host (has the keys) | `build.sh` (entry point), `release.sh`, `fetch-images.sh`, `update-snapshot.sh`, `burn.sh`, `diagnose.sh`, `test-vm.sh`, `hwtest-image.sh` |
| image configuration | `mkosi.conf` (base), `mkosi.profiles/{usb,network}/` (variants), `mkosi.profiles/{remotedesktop,docker}/` (groups), `mkosi.profiles/debug/` (`--debug`), `mkosi.repart/`, `mkosi.extra/`, `mkosi.postinst`, `mkosi.finalize`, `mkosi.postoutput` |
| initrd | `mkosi.initrd.conf/` (common), `…/mkosi.profiles/network/…/netroot` (root over HTTP), `…/mkosi.profiles/usb/…/usb-bootdev` |
| distribution server | `server/` (`setup.sh`, `safespace-netboot`, units, nginx site, `server.conf.example`) |
| shared shell code | `lib/repos.sh`, `lib/groups.sh`, `lib/keys.sh`, `lib/builds.sh` (the builds in `mkosi.output/<variant>/<groups>_<version>/`: list, select, prune), `lib/verify.sh` (also installed on the servers) |
| tests | `tests/run.sh`, `tests/lib/` |
| per-host files (gitignored, templates `*.example`) | `users.conf`, `netboot.conf`, `release.conf`, `mkosi.local.conf`, `repos.local.conf`, `server/server.conf` |

### Invariants — a change that breaks one of these needs the user's explicit OK

- **No private key in an image, a release or the repository.** Only certificates,
  signed `.auth` updates and the GUID are exported (`lib/keys.sh`);
  `mkosi.postoutput` enforces it.
- **Every image is signed**, and the UKI is signed by exactly the `db.pem` it
  ships (`mkosi.postoutput`).
- **A distribution server trusts only the pinned public `db.pem`** and never
  alters what it serves: it reports, the build host replaces. The upload account
  is confined by rrsync (write-only, no delete, share only).
- **Root only through dm-verity** with the root hash from the signed command
  line; nothing on the boot medium is ever written; `/var` is RAM.
- **One release per server and variant**, fixed file names; the initrd's
  reaction to a replaced release must not turn into a reboot loop.
- **Groups are the only difference between images** besides the variant.

### Working on it

- Run `tests/run.sh` after every change (no root, ~15 s). Add a test for new
  behaviour there: fixtures with throwaway keys are in `tests/lib/fixtures.sh`.
  A SKIP is not a pass: say which tool was missing.
- Not testable without root or hardware — say so and hand it to the user with
  the exact commands: a real `build.sh` run, `server/setup.sh`, the units under
  systemd, booting in QEMU (`test-vm.sh`) or on a machine, YubiKey keys.
- Script conventions: bash with `set -Eeuo pipefail` (the initrd scripts are
  POSIX sh); the usage text is the comment header (printed by `-h`); `log`/`die`
  helpers; validate every input that ends up in a path, a URL or a config file;
  comments say why, not what.
- Docs: every user-visible change goes into README.md (and NETBOOT.md if it
  concerns network boot) in the same change; keep the anchors working.
- PLAN.md holds the current plan; finished plans stay in git history.
