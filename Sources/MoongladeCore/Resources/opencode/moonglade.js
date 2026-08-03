// Moonglade-managed integration; reinstalls replace this file.
import { constants } from "node:fs";
import { chmod, mkdir, open, rename, unlink, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import { spawn } from "node:child_process";

const stateDirectory = join(
  process.env.MOONGLADE_HOME || join(homedir(), ".moonglade"),
  "state",
);
const sessions = new Map();
// Child sessions (subagents, title generation) mapped to the root session
// whose terminal they run in. Their prompts alert the root; every other
// child event is dropped so phantom sessions never get state documents.
const childRootSessionIDs = new Map();
const updateQueues = new Map();
const terminalSessions = new Map();
const terminalSessionLimit = 1_024;
const sessionLookupDeadlineMilliseconds = 1_000;
const maximumStateFileSize = 1_048_576;
// Events that pause a turn on the user (red alert) and the events that
// resolve that pause. Permissions and AskUserQuestion prompts share the
// same blocked-until-answered lifecycle.
const attentionAsks = new Set(["permission.asked", "question.asked"]);
const attentionResolutions = new Set([
  "permission.replied",
  "question.replied",
  "question.rejected",
]);
// Outstanding prompts per root session, keyed by the asking session so a
// dying subagent releases exactly its own prompts. Several subagents can
// prompt concurrently; answering one must not silence the others, so the
// root stays needs_attention until this ledger drains.
const pendingAsksByRoot = new Map();
const pendingAskLimit = 64;

function rootSessionID(sessionID) {
  return childRootSessionIDs.get(sessionID) ?? sessionID;
}

function isAttentionEvent(event) {
  return attentionAsks.has(event.type) || attentionResolutions.has(event.type);
}

function askRequestKey(event) {
  const requestID = attentionAsks.has(event.type)
    ? event.properties.id
    : event.properties.requestID;
  return typeof requestID === "string" && requestID !== "" ? requestID : "unkeyed";
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
  // A reply that no longer matches its recorded ask (schema drift, daemon
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

function timestamp() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

function createState(session, directory) {
  const now = timestamp();
  return {
    schema_version: 1,
    tool: "opencode",
    session_id: session.id,
    pid: process.pid,
    status: "working",
    attention_reason: null,
    cwd: session.directory || directory,
    started_at: now,
    updated_at: now,
    terminal: {
      term_program: process.env.TERM_PROGRAM || null,
      cmux_surface_id: process.env.CMUX_SURFACE_ID || null,
      iterm_session_id: process.env.ITERM_SESSION_ID || null,
      tmux_pane: process.env.TMUX_PANE || null,
      tty: null,
      window_title_hint: `${basename(session.directory || directory)} — opencode`,
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

function eventSessionID(event) {
  return event.properties.sessionID
    || event.properties.session_id
    || event.properties.info?.id;
}

function rememberTerminalSession(sessionID, phase) {
  // Bound tombstones against hostile IDs in a long-lived daemon. FIFO
  // eviction means noise arriving after more than 1,024 later deletions can
  // be reclassified, while normal trailing bursts stay suppressed.
  terminalSessions.delete(sessionID);
  terminalSessions.set(sessionID, phase);
  if (terminalSessions.size > terminalSessionLimit) {
    terminalSessions.delete(terminalSessions.keys().next().value);
  }
}

async function lookupParentSessionID(client, sessionID) {
  const controller = new AbortController();
  let timeout;
  try {
    const deadline = new Promise((resolve) => {
      timeout = setTimeout(() => {
        controller.abort();
        resolve(undefined);
      }, sessionLookupDeadlineMilliseconds);
    });
    const response = await Promise.race([
      client.session.get({ path: { id: sessionID }, signal: controller.signal }),
      deadline,
    ]);
    return response?.data?.parentID;
  } catch {
    // Fail open: a lookup hiccup must not blind the app to a real root
    // session, and the app's reaper prunes any duplicate that slips through.
    return undefined;
  } finally {
    clearTimeout(timeout);
  }
}

async function updateState(client, event, directory) {
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
    if (event.properties.info?.parentID) {
      childRootSessionIDs.set(
        sessionID,
        rootSessionID(event.properties.info.parentID),
      );
      return;
    }
    const state = createState(event.properties.info, directory);
    sessions.set(sessionID, state);
    await writeState(state);
    return;
  }
  if (event.type === "session.deleted") {
    // Mark deletion before its asynchronous write so queued noise cannot
    // recreate the session. Keep "ending" on failure to allow deletion retry.
    rememberTerminalSession(sessionID, "ending");
  }
  let state = sessions.get(sessionID);
  if (!state) {
    // Unknown mid-stream session: the plugin instance is younger than the
    // session (daemon restart). Ask the server whether it is a root
    // session before fabricating a document for it.
    const parentID = await lookupParentSessionID(client, sessionID);
    const root = parentID && parentID !== sessionID
      ? rootSessionID(parentID)
      : sessionID;
    if (root !== sessionID) {
      if (event.type === "session.deleted") {
        rememberTerminalSession(sessionID, "ended");
        return;
      }
      childRootSessionIDs.set(sessionID, root);
      migratePendingAsks(sessionID, root);
      if (isAttentionEvent(event)) {
        // Replay the prompt against the root, serialized on the root's own
        // queue. A root queue never awaits a child queue and self-mapping is
        // excluded above, so this await cannot deadlock.
        await enqueueEvent(client, root, event, directory);
      }
      return;
    }
    state = createState({ id: sessionID }, directory);
  }
  const transitions = {
    "permission.asked": ["needs_attention", "permission"],
    "permission.replied": ["working", null],
    // AskUserQuestion blocks the turn exactly like a permission prompt, and
    // Claude Code already reports it as one — reuse the "permission" reason
    // so the state schema keeps a single "agent waits on an answer" value.
    "question.asked": ["needs_attention", "permission"],
    "question.replied": ["working", null],
    "question.rejected": ["working", null],
    "session.idle": ["idle", null],
    "session.deleted": ["ended", null],
  };
  // session.status carries its own idle signal (properties.status.type ===
  // "idle") alongside the dedicated session.idle event below — OpenCode
  // 1.18 emits this one, not the dedicated event, when a turn ends. Treating
  // only busy/retry as meaningful and falling through to transitions[] (which
  // has no "session.status" key) silently dropped every idle transition,
  // leaving the spinner stuck on "working" forever.
  const statusTransition = event.type === "session.status"
    ? ["busy", "retry"].includes(event.properties.status?.type)
      ? ["working", null]
      : event.properties.status?.type === "idle"
        ? ["idle", null]
        : null
    : null;
  const transition = statusTransition ?? transitions[event.type];
  if (!transition) return;
  // While any permission or question is outstanding, only a resolution or
  // session deletion may end the wait. OpenCode can emit both busy and idle
  // noise for the paused turn, and neither may hide the alert.
  if (
    state.status === "needs_attention"
    && hasPendingAsks(sessionID)
    && !attentionResolutions.has(event.type)
    && event.type !== "session.deleted"
  ) {
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

function changesState(event) {
  return [
    "session.created",
    "session.deleted",
    "session.idle",
    ...attentionAsks,
    ...attentionResolutions,
  ].includes(event.type) || (
    event.type === "session.status"
    && ["busy", "retry", "idle"].includes(event.properties.status?.type)
  );
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

function reportUpdateError(client, error) {
  try {
    Promise.resolve(client.app.log({
      body: {
        service: "moonglade",
        level: "warn",
        message: `State update failed: ${String(error)}`,
      },
    })).catch(() => {});
  } catch {
    // Logging must not reject an OpenCode event or block later state updates.
  }
}

async function processWork(client, work, directory) {
  const sessionID = eventSessionID(work.createdEvent || work.event);
  if (work.resetSession && sessionID) {
    sessions.delete(sessionID);
    childRootSessionIDs.delete(sessionID);
  }
  if (work.createdEvent) {
    await updateState(client, work.createdEvent, directory);
  }
  await updateState(client, work.event, directory);
}

async function drainQueue(client, queue, directory) {
  while (queue.pending) {
    const work = queue.pending;
    queue.pending = undefined;
    try {
      await processWork(client, work, directory);
    } catch (error) {
      reportUpdateError(client, error);
    }
  }
}

function enqueueEvent(client, queueSessionID, event, directory) {
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
    queue.promise = drainQueue(client, queue, directory).finally(() => {
      if (updateQueues.get(queueSessionID) === queue) {
        updateQueues.delete(queueSessionID);
      }
    });
  }
  return queue.promise;
}

export const MoongladePlugin = async ({ client, directory }) => ({
  event: ({ event }) => {
    const sessionID = eventSessionID(event);
    if (!sessionID) {
      return updateState(client, event, directory).catch((error) => {
        reportUpdateError(client, error);
      });
    }

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
    return enqueueEvent(client, queueSessionID, event, directory);
  },
});
