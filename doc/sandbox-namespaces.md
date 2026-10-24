# Namespaces of the sandbox

This document says which namespaces a sandboxed tool uses, which process makes
each one, how a tool enters them, and when the processes in them are reaped and
ended. `doc/exchange-scope.md` gives the reasons for the lifetime rules,
`doc/apparmor-userns.md` the host setup, and
`doc/agent-filesystem-views-sdd.md` the filesystem views, which are a different
user of the same primitives.

## What the namespaces are for

Landlock confines paths, but it cannot deny a path under a directory that it
grants. The sandbox therefore uses three namespaces, and Landlock on top of them:

| Namespace | What it gives |
|-----------|---------------|
| user | The capabilities to make the mounts below. They are void outside it. |
| mount | The cover (denied paths and the arena hidden by empty read-only mounts), the private home, and the `mounts` of the profile. |
| PID | A private `/proc`, and a lifetime: when its init ends, the kernel ends every process in it. |

The network namespace is not used. Egress is restricted by Landlock.

The tool drops its capabilities after the mounts are made
(`fyai_fsview_drop_capabilities()`), then Landlock is applied
(`fyai_sandbox_apply()`). The program of the tool has no capability in the user
namespace, and cannot undo a mount.

`expose: [userns]` is the one case where a tool may make a user namespace of its
own (BitBake does). It gets the PID namespace and a read-only `/proc/sys`.

## Who makes the namespaces

`fyai_cover_select()` (`sandbox_cover`) picks one of three methods for each call.

| Method | Who makes the namespaces | Lifetime |
|--------|--------------------------|----------|
| holder (`FYAI_COVER_BWRAP`) | A holder that the invocation starts once for the exchange. It is an init that this program makes with `unshare()`, or a bubblewrap process where the host only allows that. | The exchange (see below). |
| per call (`FYAI_COVER_USERNS`) | The tool itself, in `fyai_fsview_hide()`, for one call. Used when `sandbox_scope: call`, or when no holder could start. | The program of the call. |
| none | No namespace. Landlock carves out the denied paths, and the orphan tracker gives the lifetime. | The tracker's. |

`auto` tries the holder made with `unshare()`, then per call, then bubblewrap.
A host that allows none of them gets `none`, a warning at the start that names the
fix, and a tool that cannot create entries in the project root.

## The holder

`fyai_fsview_holder()` starts three processes. Only the third is in the PID
namespace.

```text
invocation (owns the write end of the hold pipe)
 └─ first      new user + mount namespace; hides the cover paths; waits for second
     └─ second  the init of the new PID namespace (pid 1); mounts /proc;
                reads the hold pipe and reaps (view_holder_init)
         └─ the processes of the tools: they join, so they are children of
            the tool child outside, but members of this namespace
```

- `first` is in a group of its own, so a terminal signal does not reach it, and it
  has `PR_SET_PDEATHSIG` set: if the invocation dies, the holder dies.
- The invocation keeps the write end of a pipe. `second` reads the other end.
  The pipe is the only link: no signal, no pid file.
- The pid that the invocation uses to join is `second`, as the invocation sees it.

## How a tool enters

`fyai_cover_join()` runs in the tool child, before the command starts:

1. Open `/proc/HOLDER/ns/user`, `mnt` and `pid`.
2. `setns()` into the user namespace first, because its capabilities allow the other
   two joins, then the mount namespace, then the PID namespace.
3. Restore the working directory: joining a mount namespace resets it.
4. `fork()`. A `setns()` into a PID namespace changes only the children, so the
   child is the first process in it. The parent waits and exits with its status,
   which keeps one child for the caller.
5. Make the mounts of the profile that are not yet there, and drop capabilities.

`fyai_fsview_outer()` runs first. When a private home exists, the process that
removes its tree must stay outside the namespaces, because a mount of the tree
keeps it busy. That process waits for the child and removes the tree when the child
ends.

The per-call method does the same in one process: `fyai_fsview_hide()` makes the
namespaces with `unshare()`, hides the paths, forks the PID init
(`view_pid_init()`), and the program is its child.

## The private home and the mounts

A profile with `home: {private: true}` or `mounts` makes mounts in the same mount
namespace as the cover. `fyai_home_ensure()` builds a tree in a private directory
under `$TMPDIR`, in the invocation, before the tool starts. Inside the namespace
the tree is bound over the real `$HOME`, then the other mounts of the profile are
made. Mounts that need `/proc` are made after it is mounted (`late`). A scope shares
one mount namespace, so a mount is made once and skipped when it is there already
(`view_mount_one()`).

The tree is removed when the invocation ends, never through a mount.

## When processes are reaped and ended

Two events are different and are kept apart:

- **A process finishes.** Something must call `wait()`, or it stays a zombie.
- **The scope ends.** Every process that is left must be ended.

### Holder

- A daemon that finishes is **reaped at that moment**. The init (`second`) blocks
  `SIGCHLD` and reads it from a `signalfd`; each signal runs
  `view_holder_children()`, which calls `waitpid(-1, WNOHANG)` until nothing is
  left. This covers the processes that a tool detached: their parent is outside the
  namespace, and the kernel reparents them to the init when it ends.
- The holder is not ended when a tool call ends, or when a daemon finishes. It lives
  as long as the pipe is open: from the first call of the exchange to the end of the
  exchange, longer when a pin holds it (`doc/exchange-scope.md`).
- When the invocation closes the pipe (or ends), the init sends `SIGTERM` to every
  process (`kill(-1)`), waits up to `sandbox_grace_ms` for them to go, polling
  `/proc` of the namespace, then sends `SIGKILL`, and exits. When the init exits,
  the kernel ends whatever is left.
- A single daemon is stopped earlier with `cancel` or `/kill`: `fyai_scope_stop()`
  signals it with `SIGTERM` through a pidfd, and `SIGKILL` follows after the grace
  time. The holder is not touched.

### Per call

The init of the namespace (`view_pid_init()`) waits for the program and exits with
its status. The kernel then ends every process of the namespace at once, with no
grace time. A daemon does not outlive its call: this is what `sandbox_scope: call`
asks for.

### None (orphan tracker)

The tool child is a subreaper (`PR_SET_CHILD_SUBREAPER`), so a detached process
becomes its child. When the call ends it names these children in `detached`, and the
tool child exits; the children then become children of the host init, which reaps
each one when it finishes. The invocation holds a pidfd and the start time of each,
and ends them with `SIGTERM`, then `SIGKILL` after the grace time, when the scope
ends.

A limit: while a tool child lives, as a terminal session does, a detached process of
it that finishes stays a zombie until the tool child exits. It holds no resource but
its entry in the process table. A namespace holder does not have this limit.

## What is visible from where

- The pids in the namespace mean nothing outside it. The invocation never signals a
  pid that it read from inside: it uses the label (`FYAI_DAEMON`), read from
  `/proc/PID/environ`, and pidfds opened from outside.
- `list daemons` takes the members from `fyai_cover_members()`, which walks the
  processes whose namespace is the holder's, and from the tracker.
- The processes are visible to the user on the host, under the pids of the host.

## Failure

A namespace that cannot be made is a setup failure. With `sandbox_on_failure: warn`,
the default, fyai reports the cause one time and runs the tool without the sandbox;
with `fail` it stops the tool. A profile with mounts has no other way to work: there
is no copy fallback.
