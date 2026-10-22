# User namespaces, AppArmor and bubblewrap

A sandboxed tool needs a mount namespace to hide the project arena (`.fyai`) and
the denied paths. This page says how fyai gets one, what to do on a host that
does not allow it, and what the cost is.

## Why a namespace

Landlock cannot deny a path under a directory that it grants. The carve-out that
stands in for the denial leaves each directory above the denied path only the right
to list. A tool then cannot create a file in the project root, because `.fyai` is
there. A mount namespace hides the arena instead: the tool sees an empty read-only
directory in its place, and Landlock gets no denial.

## The three ways

`sandbox_cover` chooses. `auto`, the default, tries them in this order:

1. `userns`: the tool makes user, mount and PID namespaces itself. This needs
   unprivileged user namespaces.
2. `bwrap`: fyai starts one bubblewrap process, the holder, when the first tool
   starts. The holder makes the namespaces and covers the paths. Each tool joins
   them with `setns()`. The holder belongs to the invocation: it ends with it, and
   so does every tool in its PID namespace. This needs `bwrap` in `/usr/bin`,
   `/bin` or `/usr/local/bin`, and that the host lets it make a user namespace.
3. `none`: no cover. Landlock denies the arena, and a tool cannot create files
   directly in the project root. Files in subdirectories are not affected.

`userns` and `bwrap` choose one way and do not go on to the next. `none` is also
the choice to go without a cover and say no more about it.

## Hosts that restrict user namespaces

Ubuntu 24.04 and later restrict them with AppArmor
(`kernel.apparmor_restrict_unprivileged_userns=1`): a program that no profile
names can make a user namespace but cannot mount in it. On such a host
`userns` fails. Two fixes are available. Either one is enough.

### Install an AppArmor profile for fyai

```sh
fyai sandbox apparmor | sudo tee /etc/apparmor.d/fyai >/dev/null
sudo apparmor_parser -r /etc/apparmor.d/fyai
```

The command writes a profile for the binary that runs, named by its real path. The
profile grants `userns` and confines nothing else (`flags=(unconfined)`), as the
profiles of flatpak and chrome do. The sandbox of fyai is Landlock. A profile names a
path, so write it again after the binary moves. A package that installs
`/usr/bin/fyai` can ship the profile with that path. Site changes go in
`/etc/apparmor.d/local/fyai`.

### Install bubblewrap with its profile

```sh
sudo apt install bubblewrap apparmor-profiles
sudo install -m 644 /usr/share/apparmor/extra-profiles/bwrap-userns-restrict /etc/apparmor.d/
sudo apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict
```

fyai then uses `bwrap` when it cannot make the namespaces itself. On Ubuntu 24.04 the
bubblewrap package has no AppArmor profile, so installing the package alone does not
help: the profile is in the `apparmor-profiles` package. Later Ubuntu releases are
reported to ship and enable it. If `bwrap` still cannot make a user namespace, fyai
says so at the start, as below. The profile of fyai is the simpler fix, because it
grants the permission to the program that needs it.

### The other choice

Set `kernel.apparmor_restrict_unprivileged_userns=0` in `/etc/sysctl.d/`. It lifts
the restriction for every program of the host, so prefer the profile.

## What fyai says

When the sandbox is on, the project has a `.fyai` directory, and neither `userns`
nor `bwrap` works, fyai warns one time at the start and when the sandbox profile
changes:

```
sandbox 'dev': this host does not let fyai hide the project arena in a namespace, so a tool cannot create files in the project root. User namespaces are restricted (Ubuntu 24.04 and later) and bubblewrap is not usable
to fix it, install the AppArmor profile: `fyai sandbox apparmor | sudo tee /etc/apparmor.d/fyai >/dev/null && sudo apparmor_parser -r /etc/apparmor.d/fyai`; or install bubblewrap with its AppArmor profile (doc/apparmor-userns.md); or set `sandbox_cover: none` to keep this and say no more
```

## Check a host

```sh
sysctl kernel.apparmor_restrict_unprivileged_userns   # 1: restricted
unshare -Urnmpf true && echo userns usable
command -v bwrap
```

A test can emulate a restricted host without privilege: a user namespace in which
`/proc/sys/user/max_user_namespaces` is 0 allows no further one.

```sh
unshare -Ur sh -c 'echo 0 > /proc/sys/user/max_user_namespaces; exec fyai ...'
```

## Limits

- Sessions in a view keep the Landlock carve-out: the view hides the arena already.
- A tool that is not started by fyai, such as a program of the user in a terminal tile,
  is not covered.
- Where `bwrap` is the cover, only the paths that the holder was started with are
  hidden. A path that a later change of the configuration adds is denied by Landlock
  instead, with the cost above.
