// Moonglade-managed integration; reinstalls replace this file.
import { constants } from "node:fs";
import { chmod, mkdir, open, rename, unlink, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import { spawn } from "node:child_process";

// OpenCode 2 hosts this plugin in its shared background service, one
// instance per project location. Every instance sees every location's
// events, so each one tracks only the sessions of its own location.

const stateDirectory = join(
  process.env.MOONGLADE_HOME || join(homedir(), ".moonglade"),
  "state",
);
const terminalSessionLimit = 1_024;
const sessionLookupDeadlineMilliseconds = 1_000;
const maximumStateFileSize = 1_048_576;
// Events that pause a turn on the user (red alert) and the events that
// resolve that pause. Permissions and forms (OpenCode 2's questions) share
// the same blocked-until-answered lifecycle.
const attentionAsks = new Set(["permission.asked", "form.created"]);
const attentionResolutions = new Set([
  "permission.replied",
  "form.replied",
  "form.cancelled",
]);
const pendingAskLimit = 64;
const transitions = {
  "session.execution.started": ["working", null],
  "session.execution.succeeded": ["idle", null],
  "session.execution.failed": ["idle", null],
  "session.execution.interrupted": ["idle", null],
  "permission.asked": ["needs_attention", "permission"],
  "permission.replied": ["working", null],
  // A form blocks the turn exactly like a permission prompt, and Claude Code
  // already reports its questions as one — reuse the "permission" reason so
  // the state schema keeps a single "agent waits on an answer" value.
  "form.created": ["needs_attention", "permission"],
  "form.replied": ["working", null],
  "form.cancelled": ["working", null],
  "session.deleted": ["ended", null],
};

function isAttentionEvent(event) {
  return attentionAsks.has(event.type) || attentionResolutions.has(event.type);
}

function eventSessionID(event) {
  const sessionID = event.data?.sessionID ?? event.data?.form?.sessionID;
  return typeof sessionID === "string" && sessionID !== "" ? sessionID : undefined;
}

function askRequestKey(event) {
  const requestID = event.type === "form.created"
    ? event.data.form?.id
    : event.type === "permission.replied"
      ? event.data.requestID
      : event.data.id;
  return typeof requestID === "string" && requestID !== "" ? requestID : "unkeyed";
}

function timestamp() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

/// The name OpenCode gives a session once its first turn is summarized. It is
/// the only value that tells the app which terminal pane hosts this session,
/// so it is normalized here rather than anywhere downstream.
function sessionTitle(title) {
  return typeof title === "string" && title.trim() !== "" ? title.trim() : null;
}

/// Where a session runs: its location plus the subdirectory it was opened in.
function sessionDirectory(location, subpath) {
  const directory = location?.directory;
  if (typeof directory !== "string" || directory === "") return undefined;
  return typeof subpath === "string" && subpath !== "" ? join(directory, subpath) : directory;
}

function createState({ id, title, cwd }) {
  const now = timestamp();
  const termProgram = process.env.TERM_PROGRAM || null;
  return {
    schema_version: 1,
    tool: "opencode",
    session_id: id,
    session_title: sessionTitle(title),
    pid: process.pid,
    status: "working",
    attention_reason: null,
    cwd,
    started_at: now,
    updated_at: now,
    terminal: {
      term_program: termProgram,
      orca_terminal_handle: termProgram?.toLowerCase() === "orca"
        ? process.env.ORCA_TERMINAL_HANDLE || null
        : null,
      cmux_surface_id: process.env.CMUX_SURFACE_ID || null,
      herdr_pane_id: process.env.HERDR_PANE_ID || null,
      herdr_socket_path: process.env.HERDR_SOCKET_PATH || null,
      iterm_session_id: process.env.ITERM_SESSION_ID || null,
      tmux_pane: process.env.TMUX_PANE || null,
      tty: null,
      window_title_hint: `${basename(cwd)} — opencode`,
    },
  };
}

function isSecureStateFile(metadata) {
  return metadata.isFile()
    && metadata.uid === BigInt(process.getuid())
    && (metadata.mode & 0o022n) === 0n
    && metadata.size >= 0n
    && metadata.size <= BigInt(maximumStateFileSize);
}

function hasSameFingerprint(before, after) {
  return before.dev === after.dev
    && before.ino === after.ino
    && before.mode === after.mode
    && before.nlink === after.nlink
    && before.uid === after.uid
    && before.gid === after.gid
    && before.size === after.size
    && before.mtimeNs === after.mtimeNs
    && before.ctimeNs === after.ctimeNs;
}

async function readExistingState(path) {
  let handle;
  try {
    handle = await open(
      path,
      constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
    );
    const before = await handle.stat({ bigint: true });
    if (!isSecureStateFile(before)) return undefined;

    const chunks = [];
    let byteCount = 0;
    while (byteCount <= maximumStateFileSize) {
      const remaining = maximumStateFileSize + 1 - byteCount;
      const chunk = Buffer.allocUnsafe(Math.min(64 * 1_024, remaining));
      const { bytesRead } = await handle.read(chunk, 0, chunk.length, null);
      if (bytesRead === 0) break;
      chunks.push(chunk.subarray(0, bytesRead));
      byteCount += bytesRead;
    }

    const after = await handle.stat({ bigint: true });
    if (
      !isSecureStateFile(after)
      || !hasSameFingerprint(before, after)
      || byteCount > maximumStateFileSize
      || BigInt(byteCount) !== after.size
    ) {
      return undefined;
    }
    return JSON.parse(Buffer.concat(chunks, byteCount).toString("utf8"));
  } catch {
    return undefined;
  } finally {
    try {
      await handle?.close();
    } catch {
      // Existing state is optional authority; close failures cannot block a write.
    }
  }
}

async function writeState(state) {
  const sessionID = Buffer.from(state.session_id, "utf8");
  if (sessionID.length > 128) throw new Error("Moonglade session ID exceeds 128 bytes");
  const safeID = sessionID.toString("base64url");
  const destination = join(stateDirectory, `opencode-${safeID}.json`);
  // OpenCode does not serialize event delivery: a burst of events for the
  // same session can call writeState concurrently. A temp name fixed per
  // session+pid let one call's rename consume another's temp file first,
  // failing the loser's rename with ENOENT and silently dropping that
  // status transition. A unique name per call removes the collision.
  const temporary = join(stateDirectory, `.${safeID}-${process.pid}-${randomUUID()}.tmp`);
  await mkdir(stateDirectory, { recursive: true, mode: 0o700 });
  await chmod(stateDirectory, 0o700);
  delete state.process_identity;
  const existing = await readExistingState(destination);
  const identity = existing?.process_identity;
  if (
    existing?.schema_version === state.schema_version
    && existing.tool === state.tool
    && existing.session_id === state.session_id
    && existing.pid === state.pid
    && existing.started_at === state.started_at
    && identity?.pid === state.pid
    && Number.isSafeInteger(identity.kernel_start_time_us)
    && identity.kernel_start_time_us >= 0
  ) {
    state.process_identity = identity;
  }
  let writeError;
  try {
    await writeFile(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
    await rename(temporary, destination);
  } catch (error) {
    writeError = error;
    throw error;
  } finally {
    if (writeError) {
      try {
        await unlink(temporary);
      } catch (cleanupError) {
        if (cleanupError.code !== "ENOENT") writeError.cleanupError = cleanupError;
      }
    }
  }
  // Spawn failures surface as asynchronous "error" events; without a
  // listener they would crash the host process. A missed notification is
  // harmless — the app also observes the state directory directly.
  const notifier = spawn("/usr/bin/notifyutil", ["-p", "com.moonglade.stateChanged"], {
    stdio: "ignore",
  });
  notifier.on("error", () => {});
  notifier.unref();
}

async function findSession(lookupSession, sessionID) {
  let timeout;
  try {
    const deadline = new Promise((resolve) => {
      timeout = setTimeout(() => resolve(undefined), sessionLookupDeadlineMilliseconds);
    });
    return await Promise.race([
      Promise.resolve().then(() => lookupSession(sessionID)),
      deadline,
    ]);
  } catch {
    // Every location's instance sees this session, so an unanswered lookup
    // cannot tell whose it is. Treat it as unknown; the next event retries.
    return undefined;
  } finally {
    clearTimeout(timeout);
  }
}

function changesState(event) {
  // session.renamed carries the session title; it moves no status but must
  // not be coalesced away behind unrelated noise.
  return event.type === "session.created"
    || event.type === "session.renamed"
    || Object.hasOwn(transitions, event.type);
}

function coalesceWork(work, event) {
  if (!work) {
    return { event, createdEvent: undefined, resetSession: false };
  }
  if (work.event.type === "session.deleted" && event.type !== "session.created") {
    return work;
  }
  if (event.type === "session.deleted") {
    return { event, createdEvent: undefined, resetSession: work.resetSession };
  }
  if (event.type === "session.created") {
    return {
      event,
      createdEvent: undefined,
      resetSession: work.resetSession || work.event.type === "session.deleted",
    };
  }
  if (!changesState(event)) {
    return changesState(work.event) ? work : { ...work, event };
  }
  // An unanswered ask must survive coalescing so its needs_attention write
  // lands; the pending-ask ledger (mutated at intake, never here) already
  // reflects every ask and resolution the burst carried.
  if (attentionAsks.has(work.event.type) && !attentionResolutions.has(event.type)) {
    return work;
  }
  return {
    event,
    createdEvent: work.createdEvent
      || (work.event.type === "session.created" ? work.event : undefined),
    resetSession: work.resetSession,
  };
}

/// Tracks the sessions of one OpenCode location and mirrors them into
/// Moonglade state documents. `lookupSession` resolves a session ID to the
/// server's session record; `reportError` receives failed state writes.
export function createSessionTracker({ directory, lookupSession, reportError }) {
  const sessions = new Map();
  // Child sessions (subagents, title generation) mapped to the root session
  // whose terminal they run in. Their prompts alert the root; every other
  // child event is dropped so phantom sessions never get state documents.
  const childRootSessionIDs = new Map();
  const updateQueues = new Map();
  // Sessions whose events are ignored until they are created again: deleted
  // ones ("ending", "ended") and ones another location owns ("foreign").
  const terminalSessions = new Map();
  // Outstanding prompts per root session, keyed by the asking session so a
  // dying subagent releases exactly its own prompts. Several subagents can
  // prompt concurrently; answering one must not silence the others, so the
  // root stays needs_attention until this ledger drains.
  const pendingAsksByRoot = new Map();

  function rootSessionID(sessionID) {
    return childRootSessionIDs.get(sessionID) ?? sessionID;
  }

  function recordPendingAsk(root, asker, key) {
    let asksBySession = pendingAsksByRoot.get(root);
    if (!asksBySession) {
      asksBySession = new Map();
      pendingAsksByRoot.set(root, asksBySession);
    }
    let keys = asksBySession.get(asker);
    if (!keys) {
      if (asksBySession.size >= pendingAskLimit) {
        asksBySession.delete(asksBySession.keys().next().value);
      }
      keys = new Set();
      asksBySession.set(asker, keys);
    }
    keys.add(key);
    if (keys.size > pendingAskLimit) keys.delete(keys.values().next().value);
  }

  function resolvePendingAsk(root, asker, key) {
    const asksBySession = pendingAsksByRoot.get(root);
    const keys = asksBySession?.get(asker);
    if (!keys) return;
    // A reply that no longer matches its recorded ask (schema drift, service
    // restart) still means the user answered something: retire the oldest.
    if (!keys.delete(key)) keys.delete(keys.values().next().value);
    if (keys.size === 0) asksBySession.delete(asker);
    if (asksBySession.size === 0) pendingAsksByRoot.delete(root);
  }

  function hasPendingAsks(root) {
    return pendingAsksByRoot.has(root);
  }

  function releasePendingAsks(asker) {
    const asksBySession = pendingAsksByRoot.get(rootSessionID(asker));
    if (!asksBySession) return;
    asksBySession.delete(asker);
    if (asksBySession.size === 0) pendingAsksByRoot.delete(rootSessionID(asker));
  }

  function migratePendingAsks(fromRoot, toRoot) {
    const stranded = pendingAsksByRoot.get(fromRoot);
    if (!stranded) return;
    pendingAsksByRoot.delete(fromRoot);
    for (const [asker, keys] of stranded) {
      for (const key of keys) recordPendingAsk(toRoot, asker, key);
    }
  }

  function rememberTerminalSession(sessionID, phase) {
    // Bound tombstones against hostile IDs in a long-lived service. FIFO
    // eviction means noise arriving after more than 1,024 later deletions can
    // be reclassified, while normal trailing bursts stay suppressed.
    terminalSessions.delete(sessionID);
    terminalSessions.set(sessionID, phase);
    if (terminalSessions.size > terminalSessionLimit) {
      terminalSessions.delete(terminalSessions.keys().next().value);
    }
  }

  function ignoreForeignSession(sessionID) {
    sessions.delete(sessionID);
    pendingAsksByRoot.delete(sessionID);
    rememberTerminalSession(sessionID, "foreign");
  }

  async function trackCreatedSession(sessionID, data) {
    if (data.location?.directory !== directory) {
      ignoreForeignSession(sessionID);
      return;
    }
    if (data.parentID) {
      childRootSessionIDs.set(sessionID, rootSessionID(data.parentID));
      return;
    }
    const state = createState({
      id: sessionID,
      title: data.title,
      cwd: sessionDirectory(data.location, data.subpath),
    });
    sessions.set(sessionID, state);
    await writeState(state);
  }

  /// Rebuilds a session this instance never saw created: the service can load
  /// the plugin after the session began. Returns the state to update, or
  /// undefined when the event was settled elsewhere (child, foreign session).
  async function recoverUnknownSession(sessionID, event) {
    const info = await findSession(lookupSession, sessionID);
    const owner = info?.location?.directory;
    // Only the instance of the session's own location may write its document;
    // a failed lookup proves nothing, so it writes nothing until a retry.
    if (typeof owner !== "string") return undefined;
    if (owner !== directory) {
      ignoreForeignSession(sessionID);
      return undefined;
    }
    const parentID = info.parentID;
    const root = parentID && parentID !== sessionID ? rootSessionID(parentID) : sessionID;
    if (root === sessionID) {
      return createState({
        id: sessionID,
        title: info.title,
        cwd: sessionDirectory(info.location, info.subpath),
      });
    }
    if (event.type === "session.deleted") {
      rememberTerminalSession(sessionID, "ended");
      return undefined;
    }
    childRootSessionIDs.set(sessionID, root);
    migratePendingAsks(sessionID, root);
    if (isAttentionEvent(event)) {
      // Replay the prompt against the root, serialized on the root's own
      // queue. A root queue never awaits a child queue and self-mapping is
      // excluded above, so this await cannot deadlock.
      await enqueueEvent(root, event);
    }
    return undefined;
  }

  async function updateState(event) {
    const eventSession = eventSessionID(event);
    if (!eventSession) return;
    // A prompt raised inside a subagent blocks the user in the root session's
    // terminal, so its lifecycle is applied to the root's document.
    const sessionID = isAttentionEvent(event)
      ? rootSessionID(eventSession)
      : eventSession;
    const terminalPhase = terminalSessions.get(sessionID);
    if (event.type === "session.created") {
      terminalSessions.delete(sessionID);
    } else if (
      terminalPhase === "ended"
      || terminalPhase === "foreign"
      || (terminalPhase === "ending" && event.type !== "session.deleted")
    ) {
      return;
    }
    if (childRootSessionIDs.has(sessionID)) {
      if (event.type === "session.deleted") {
        releasePendingAsks(sessionID);
        childRootSessionIDs.delete(sessionID);
        rememberTerminalSession(sessionID, "ended");
      }
      return;
    }
    if (event.type === "session.created") {
      await trackCreatedSession(sessionID, event.data);
      return;
    }
    if (event.type === "session.deleted") {
      // Mark deletion before its asynchronous write so queued noise cannot
      // recreate the session. Keep "ending" on failure to allow deletion retry.
      rememberTerminalSession(sessionID, "ending");
    }
    let state = sessions.get(sessionID);
    if (!state) {
      // A retitle is metadata about a session, not evidence that anyone is
      // running it: OpenCode emits it for archived sessions too. Fabricating a
      // document from one would put a row in the notch for nothing.
      if (event.type === "session.renamed") return;
      state = await recoverUnknownSession(sessionID, event);
      if (!state) return;
    }
    const transition = transitions[event.type];
    const title = event.type === "session.renamed" ? sessionTitle(event.data.title) : null;
    const retitled = title !== null && title !== state.session_title;
    if (retitled) state.session_title = title;
    // While any permission or form is outstanding, only a resolution or
    // session deletion may end the wait. OpenCode can report the paused turn
    // as started or ended, and neither may hide the alert.
    const blockedByPendingAsks = state.status === "needs_attention"
      && hasPendingAsks(sessionID)
      && !attentionResolutions.has(event.type)
      && event.type !== "session.deleted";
    if (!transition || blockedByPendingAsks) {
      // A retitle carries no status of its own, so it still has to be persisted
      // when the event that delivered it moves nothing else.
      if (retitled) {
        state.updated_at = timestamp();
        sessions.set(sessionID, state);
        await writeState(state);
      }
      return;
    }
    let [status, attentionReason] = transition;
    if (attentionResolutions.has(event.type) && hasPendingAsks(sessionID)) {
      // The answered prompt was not the last outstanding one; the session is
      // still blocked on the user.
      [status, attentionReason] = ["needs_attention", "permission"];
    }
    state.status = status;
    state.attention_reason = attentionReason;
    state.updated_at = timestamp();
    sessions.set(sessionID, state);
    await writeState(state);
    if (event.type === "session.deleted") {
      sessions.delete(sessionID);
      pendingAsksByRoot.delete(sessionID);
      rememberTerminalSession(sessionID, "ended");
    }
  }

  function reportUpdateError(error) {
    try {
      reportError(error);
    } catch {
      // Reporting must not reject an OpenCode event or block later updates.
    }
  }

  async function processWork(work) {
    const sessionID = eventSessionID(work.createdEvent || work.event);
    if (work.resetSession && sessionID) {
      sessions.delete(sessionID);
      childRootSessionIDs.delete(sessionID);
    }
    if (work.createdEvent) {
      await updateState(work.createdEvent);
    }
    await updateState(work.event);
  }

  async function drainQueue(queue) {
    while (queue.pending) {
      const work = queue.pending;
      queue.pending = undefined;
      try {
        await processWork(work);
      } catch (error) {
        reportUpdateError(error);
      }
    }
  }

  function enqueueEvent(queueSessionID, event) {
    let queue = updateQueues.get(queueSessionID);
    if (queue) {
      // A burst shares this drain promise and only mutates one pending work
      // item, so neither promises nor event closures form an unbounded chain.
      queue.pending = coalesceWork(queue.pending, event);
    } else {
      queue = {
        pending: coalesceWork(undefined, event),
        promise: undefined,
      };
      updateQueues.set(queueSessionID, queue);
      queue.promise = drainQueue(queue).finally(() => {
        if (updateQueues.get(queueSessionID) === queue) {
          updateQueues.delete(queueSessionID);
        }
      });
    }
    return queue.promise;
  }

  /// Applies one OpenCode event. The returned promise settles once the state
  /// documents reflect it; it never rejects.
  function receive(event) {
    const sessionID = eventSessionID(event);
    if (!sessionID) return Promise.resolve();

    let queueSessionID = sessionID;
    if (isAttentionEvent(event)) {
      // Record every ask and resolution before coalescing can collapse the
      // burst: three concurrent subagent prompts must keep the root red
      // until the third answer, even when their events share one queue drain.
      const root = rootSessionID(sessionID);
      if (!terminalSessions.has(root)) {
        if (attentionAsks.has(event.type)) {
          recordPendingAsk(root, sessionID, askRequestKey(event));
        } else {
          resolvePendingAsk(root, sessionID, askRequestKey(event));
        }
      }
      queueSessionID = root;
    }
    return enqueueEvent(queueSessionID, event);
  }

  return { receive };
}

async function consumeEvents(events, tracker, signal, reportError) {
  try {
    for await (const event of events) {
      // Not awaited: a stalled session lookup must not hold back the events
      // of every other session. Per-session queues keep each one ordered.
      void tracker.receive(event);
    }
    if (!signal.aborted) reportError(new Error("OpenCode event stream ended"));
  } catch (error) {
    if (!signal.aborted) reportError(error);
  }
}

function reportToConsole(error) {
  console.error(`Moonglade state update failed: ${String(error)}`);
}

export default {
  id: "moonglade.opencode",
  setup(ctx, reportError = reportToConsole) {
    const controller = new AbortController();
    const tracker = createSessionTracker({
      directory: ctx.location.directory,
      lookupSession: (sessionID) => ctx.session.get({ sessionID }),
      reportError,
    });
    void consumeEvents(
      ctx.event.subscribe({ signal: controller.signal }),
      tracker,
      controller.signal,
      reportError,
    );
    return () => controller.abort();
  },
};
