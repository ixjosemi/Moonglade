// Moonglade-managed integration; reinstalls replace this file.
// Moonglade session-status extension for Pi (https://github.com/badlogic/pi-mono).
// Installed by `moonglade install` into ~/.pi/agent/extensions/. Mirrors the
// OpenCode plugin: every lifecycle event is persisted as a versioned state
// document under ~/.moonglade/state for the notch app to observe.
import { constants } from "node:fs";
import { chmod, mkdir, open, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import { spawn } from "node:child_process";

const stateDirectory = join(
  process.env.MOONGLADE_HOME || join(homedir(), ".moonglade"),
  "state",
);
const sessions = new Map();
const maximumStateFileSize = 1_048_576;

function timestamp() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

function sessionID(ctx) {
  return ctx?.sessionManager?.getSessionId?.() || `pid-${process.pid}`;
}

function createState(id, cwd) {
  const now = timestamp();
  return {
    schema_version: 1,
    tool: "pi",
    session_id: id,
    pid: process.pid,
    status: "working",
    attention_reason: null,
    cwd,
    started_at: now,
    updated_at: now,
    terminal: {
      term_program: process.env.TERM_PROGRAM || null,
      cmux_surface_id: process.env.CMUX_SURFACE_ID || null,
      iterm_session_id: process.env.ITERM_SESSION_ID || null,
      tmux_pane: process.env.TMUX_PANE || null,
      tty: null,
      window_title_hint: `${basename(cwd)} — pi`,
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
  const encoded = Buffer.from(state.session_id, "utf8");
  if (encoded.length > 128) throw new Error("Moonglade session ID exceeds 128 bytes");
  const safeID = encoded.toString("base64url");
  const destination = join(stateDirectory, `pi-${safeID}.json`);
  const temporary = join(stateDirectory, `.${safeID}-${process.pid}.tmp`);
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
  await writeFile(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, destination);
  // Spawn failures surface as asynchronous "error" events; without a
  // listener they would crash the host process. A missed notification is
  // harmless — the app also observes the state directory directly.
  const notifier = spawn("/usr/bin/notifyutil", ["-p", "com.moonglade.stateChanged"], {
    stdio: "ignore",
  });
  notifier.on("error", () => {});
  notifier.unref();
}

async function transition(ctx, status, attentionReason) {
  const id = sessionID(ctx);
  const state = sessions.get(id) || createState(id, ctx?.cwd || process.cwd());
  state.status = status;
  state.attention_reason = attentionReason ?? null;
  state.updated_at = timestamp();
  sessions.set(id, state);
  await writeState(state);
}

let warnedOnce = false;

function guarded(handler) {
  return async (event, ctx) => {
    try {
      await handler(event, ctx);
    } catch (error) {
      if (!warnedOnce) {
        warnedOnce = true;
        console.error(`moonglade: state update failed: ${String(error)}`);
      }
    }
  };
}

export default function moonglade(pi) {
  pi.on("session_start", guarded(async (_event, ctx) => transition(ctx, "working")));
  pi.on("input", guarded(async (_event, ctx) => transition(ctx, "working")));
  pi.on("agent_start", guarded(async (_event, ctx) => transition(ctx, "working")));
  pi.on(
    "agent_end",
    guarded(async (_event, ctx) => transition(ctx, "idle", "turn_complete")),
  );
  pi.on("session_before_switch", guarded(async (_event, ctx) => transition(ctx, "ended")));
  pi.on("session_shutdown", guarded(async (_event, ctx) => transition(ctx, "ended")));
}
