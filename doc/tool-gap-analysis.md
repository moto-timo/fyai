# Tool gap analysis

Updated 2026-10-12 against commit `071131ef24b46f1a231e7c35c0ae777209b0b6e3`.
This review reconciles the two root reports,
[`fyai-gap-analysis-2026-10-08.md`](../fyai-gap-analysis-2026-10-08.md) and
[`fyai-alternative-harness-gap-analysis-2026-10-09.md`](../fyai-alternative-harness-gap-analysis-2026-10-09.md),
with the current native tool schema. It is a source and documentation comparison,
not a benchmark, test run, or security audit. An absent native tool may still have
a shell or MCP workaround. No P0 defect is established by these reviews.

## Executive conclusion

fyai already has a substantial local coding loop, a branch-stored todo list,
multiquestion user interaction, background and supervised agents with
structured messages and receipts, branch-stored skills, and isolated Linux
project views. The earlier analysis described several of these as missing. The
broad remaining opportunities are trusted lifecycle extensions,
provider-independent URL retrieval, MCP resources and deferred discovery, and a
stable external session control protocol.
Image inspection, durable unattended execution, and editor clients depend more
strongly on the intended audience.

Preserve the stateless invocation, content-addressed history, existing sandbox,
and project-view model. Feature-name parity with another harness is not a reason
to add a daemon, a second store, or a new isolation policy.

## Evidence and current native surface

`data/tools.yaml` defines **20** model tools:

| Area | Tools | Current capability |
| --- | --- | --- |
| Files and commands | `read_file`, `write_file`, `apply_patch`, `exec_command` | Text editing, patches, foreground commands, and PTY sessions. |
| Live sessions | `shell_input`, `shell_output`, `shell_close`, `monitor` | Named shell interaction and bounded event monitoring. |
| Agents | `agent`, `agent_message`, `agent_input`, `ask_parent`, `list`, `cancel`, `project_view` | Fork/fresh context, background launch, status, cancellation, queued messages with receipts, input while waiting, questions to the owning agent, isolated views, change inspection, and conflict-aware apply. |
| Skills | `skill` | Loads a branch-stored skill, or runs a forked skill as a sub-agent. |
| Planning, interaction, and time | `todo_write`, `ask_user`, `time`, `wait` | Branch-stored task lists; one to four questions with stable IDs, descriptions, previews, multi-select, free text, and background answers; interruptible waits. |

The `agent` schema supports `background` and `isolated`; `list` exposes agent
state; `cancel` stops agents, monitors, waits, shells, and message receipts.
`agent_input` answers an agent waiting for input. `agent_message` queues a
message for a live agent without blocking the turn: the receipt is a `wait`
target and appears in `list`, and the recipient consumes the message at its
next model request boundary or after a completed turn. A reply is a separate
message that sets `reply_to`. Isolated project views are an implemented alternative to Git
worktrees on supported Linux hosts. The relevant source is
[`data/tools.yaml`](../data/tools.yaml), with agent behavior described in
[`agent-protocol.md`](agent-protocol.md) and filesystem views in
[`agent-filesystem-views-sdd.md`](agent-filesystem-views-sdd.md).

`todo_write` replaces the branch's list. `fyai todo` and `/todo` show it;
`todo clear` drops it. A sub-agent branch inherits its parent's list and can
then change its own copy. The live panel shows the list when it fits. A list
whose items are all completed or cancelled is cleared after publication, with
the finished version retained in the branch reflog. The root's `ask_user` can
ask up to four questions in one call and collect answers in a review. A live
sub-agent uses `ask_parent` for its delegating agent. Named questions work with
`list`, `wait`, and `cancel`. See the [user guide](user-guide.md) for the
interaction and [todo commands](commands.md#fyai-todo) for branch behavior.

A skill is a `SKILL.md` and its files, stored in the branch member `skills` as
[`skills.md`](skills.md) describes. It enters the store only through
`skill import`, `skill new`, or `skill edit`; fyai does not discover skills in
the filesystem. The model loads one with the `skill` tool and the user runs one
as `/NAME` or `skill exec`. `skill import --claude SCOPE` reads the skills and
commands of Claude Code, including plugin skills. A skill with
`context: fork` runs as a sub-agent through the `agent` tool, with its
`allowed-tools` enforced, and can be isolated, backgrounded, and time limited.
Skills follow the configuration across branches, sub-agents, and concurrent
publishes. A skill with files is written to a private `mkdtemp()` directory so
its programs run.

Other existing foundations include MCP tool calls over stdio and Streamable
HTTP with OAuth; provider-hosted web search on endpoints declaring support;
project instruction discovery; conversation branches, merge/rebase, compaction,
and foreign import. These capabilities have different boundaries from a native
URL-fetch tool, MCP resource reader, portable skill loader, or durable job
controller. Availability in source is not a production reliability claim.

### Corrections to the earlier reviews

| Former claim | Current assessment |
| --- | --- |
| 12 native tools | 20 definitions in `data/tools.yaml`. |
| No native task list | `todo_write` publishes a list in branch state and the live page shows it. |
| Only simple, serial clarification | `ask_user` supports one to four questions, structured options and answers, previews, multi-select, and background calls. |
| No model-facing agent status or cancellation | `list` and `cancel` provide both. |
| No background agent mode | `agent.background` runs work concurrently within the owning invocation and delivers completion in a later turn. |
| No workspace isolation | `agent.isolated` and `project_view` provide private project copies, inspection, and conflict-aware apply on supported Linux hosts. |
| Agent lifecycle must precede isolation | Both foundations exist. The narrower remaining gap is external session control. |
| No way to steer a busy agent | `agent_message` queues attributed messages with receipts, and `ask_parent` lets a child question its owner. Delivery is at a request boundary; a running tool call is not preempted. |
| No portable skill loader | Branch-stored skills, the `skill` tool, `/NAME`, forked skills, and Claude Code import exist. Lifecycle hooks and shareable packages remain open. |

## Gap assessment

| Area | fyai boundary today | Useful next contract | Priority |
| --- | --- | --- | --- |
| Extensions | Skills are branch state with explicit import; no lifecycle hook or trusted extension contract established | Bounded trusted hooks with timeouts and output limits; a shareable package format beyond Claude Code import | P1 |
| Busy-agent steering | `agent_message` receipts and `ask_parent`; delivery at a model request boundary | Decide whether preempting a long tool call is needed; characterize delivery latency | P3 |
| Web retrieval | Hosted search depends on endpoint; no native bounded URL fetch | Provider-independent fetch with URL, title, time, source, limits, network policy, and replayable citation metadata | P1 |
| MCP breadth | Tool calls, OAuth, resource/template list and reads, deferred tool discovery, and HTTP session recovery work; only selected schemas from a large catalog enter requests | Measure context savings with real large catalogs; test OAuth expiry for resource reads | P1 |
| External control | One-run worker RPC and internal agent protocol; no stable durable-session client contract established | Versioned branch open/resume, input, correlated events, questions, cancellation, and reconnect semantics | P1 |
| Visual input | Native reader is text-oriented | MIME and size checks, capability negotiation, durable attachment identity, provider serialization, replay | P2; P1 for frontend work |
| Recovery of unfinished effects | Durable conversation history; no general execution-intent/replay contract established | Characterize crash boundaries before optional unattended jobs; classify ambiguous effects and deduplicate submissions | P2; P1 for unattended work |
| Editor and automation clients | Terminal-first CLI | Build a thin client against the session contract; consider ACP after demonstrated compatibility | P2 |
| Diagnostics and special formats | Shell/MCP composition; no dedicated LSP, notebook edit, or artifact lifecycle | Add only against measured failures or a chosen workload | P2/P3 |
| Hosted scheduling | Invocation owns its lifetime | External controller owns scheduling and durable jobs if required | P3 |

### Planning and interaction

The todo list is branch state in the content-addressed arena. A full-list
rewrite records the status and priority of each item; `todo clear` removes the
current list. The finished list remains reachable through the branch reflog.
This supplies a durable task snapshot across invocations, although it is not
an execution scheduler. `ask_user` already provides stable question and option
IDs, free-text and multi-select answers, previews, explicit decline, and
background questions that can be listed, waited on, or cancelled. A busy
agent receives acknowledged messages through `agent_message`. The receipt
confirms queueing only, and a message already sent cannot be retracted.

### Retrieval and MCP

Hosted web search is already adapted for capable provider endpoints, but it
does not make a selected URL retrievable across providers. A native fetch must
bound redirects, time, size, and MIME types; use the existing network controls;
and preserve source and failure information in transcript replay. Do not route
it invisibly through shell output. MCP resources and templates are distinct
from MCP tool results. The resource tool returns one page at a time and caps a
response at 64 KiB. A catalog with more than eight tools exposes a bounded
search; selected schemas enter later model requests. Measure context savings
and selection quality with real large catalogs, and exercise resource reads
after OAuth recovery.

### Skills, extensions, and external control

Project instructions are already discovered, and skills now supply explicit
import, on-demand loading, invocation, and per-branch state, with the first
source of a name winning on import. The open parts are hooks and a shareable
package format. Hooks need trust, timeouts, output bounds, and no automatic execution merely
because a repository contains one. A small subprocess event/tool contract fits
the native executable. A stable session API can use subprocesses without a
resident server; it should be distinguished from the existing transient worker
RPC. Demonstrate it with one client before claiming ACP compatibility.

### Durability and visual work

Stored conversation history is not the same guarantee as restart-safe tool
execution. A crash after an external effect but before its result is committed
can make a blind replay destructive. First document and fault-test the current
boundary. If unattended jobs are needed, record execution intent, interruption
outcomes, submission IDs, and ownership in the existing storage architecture.

For visual coding, image inspection and screenshot input should precede image
generation. Provider capability checks, binary attachment references, and
transcript replay are prerequisites. PDF and browser attachment flows are
separate integrations. Dedicated glob/grep, exact-string edit, notebook, and
LSP tools should follow measured failures rather than tool-count parity.

## Comparison context

| Comparator | Useful lesson | Boundary to keep clear |
| --- | --- | --- |
| Claude Code and Codex | Plans, skills/hooks, structured questions, web access, and external workflows | Different approval and sandbox policies do not imply a fyai security defect. |
| OpenCode V1 and V2 | Connected daily workflow and broad tool composition | V1 and V2 differ; V2 browser tools depend on an attached desktop, and V2 omits V1 LSP tooling. |
| Archived Go OpenCode / Crush | Crush is the live successor and a native-terminal packaging comparator | Do not build toward the archived project. |
| Pi | Extensions, packages, session navigation, SDK/RPC, and current MCP resource/deferred exposure modes | Its base agent intentionally leaves some fyai-native features to extensions. |
| Pi Durable | Explicit execution intent, replay policy, and child ownership | Experimental durable orchestration differs from durable conversation storage and gives no universal exactly-once effects. |
| Goose, Cline, OpenHands, DeepSeek Harness | Recipes, external clients, ACP/control planes, and extensibility | Hosted or application breadth is not automatically a core CLI requirement. |

The companion reports contain pinned source links and detailed version notes.
They are the evidence for competitor claims; this document keeps the actionable
fyai assessment in one place. No source comparison establishes which harness
solves more coding tasks, costs less, or has stronger security in practice.

## Recommended sequence and acceptance evidence

1. Keep the native-tool inventory mechanically checked against this review and
   establish a small reproducible task evaluation. Do not treat tool count as
   a quality score.
2. Evaluate the existing todo, ask-user, and agent-message flows on resumed
   and delegated work.
3. Add a trusted extension contract for hooks. Demonstrate one shareable
   skill-based workflow without changing core source.
4. Add bounded URL fetch, MCP resource access, and deferred discovery. Verify
   retrieval replay and measure prompt cost with a large MCP catalog.
5. Expose a versioned durable-session event/control contract and validate one
   external client. Keep scheduling outside the invocation-owned core.
6. Choose workload-specific investments: image inspection for frontend work;
   recovery semantics for unattended work; diagnostics or editor integration
   when task evidence supports them.

For each implemented feature, verify its schema and state transitions, provider
serialization where relevant, cancellation, sink presentation, transcript
replay, and foreign-import preservation. Evaluate representative bug fixes,
multi-file changes, resumed sessions, concurrent edits, large MCP catalogs,
and screenshot or interrupted-job cases when those workloads are in scope.
Track completion, regression, time, cost, intervention, and recovery across
repeated runs. Keep imported calls inert until an equivalent execution contract
exists.

## Architectural constraints

Do not add model-controlled sandbox escape, raw credentials in tool arguments,
a resident daemon, numeric durable object references, a sidecar task store, or
a second transcript renderer to match another harness. Preserve the current
Landlock and project-view architecture. A future security recommendation needs
a concrete defect against fyai's intended guarantees; the two source reviews
do not establish one.
