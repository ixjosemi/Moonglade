import assert from "node:assert/strict";
import fs from "node:fs";
import { spawn } from "node:child_process";
import { syncBuiltinESMExports } from "node:module";
import {
  appendFile,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const home = await mkdtemp(join(tmpdir(), "moonglade-opencode-"));
process.env.MOONGLADE_HOME = home;
process.env.TERM_PROGRAM = "ghostty";
process.env.ORCA_TERMINAL_HANDLE = "not-an-orca-terminal";

const originalOpen = fs.promises.open.bind(fs.promises);
let stateReadBarrier;
fs.promises.open = async (...arguments_) => {
  const handle = await originalOpen(...arguments_);
  if (stateReadBarrier?.path === String(arguments_[0])) {
    const barrier = stateReadBarrier;
    stateReadBarrier = undefined;
    const originalStat = handle.stat.bind(handle);
    handle.stat = async (...statArguments) => {
      const metadata = await originalStat(...statArguments);
      barrier.didStat();
      await barrier.release;
      return metadata;
    };
  }
  return handle;
};
syncBuiltinESMExports();

function pauseStateReadAfterStat(path) {
  let didStat;
  let resume;
  const reached = new Promise((resolve) => { didStat = resolve; });
  const release = new Promise((resolve) => { resume = resolve; });
  stateReadBarrier = { path, didStat, release };
  return { reached, resume };
}

function runNodeDriver(driverURL, environment, timeoutMilliseconds = 1_500) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [driverURL], {
      env: { ...process.env, ...environment },
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    let timedOut = false;
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    const timeout = setTimeout(() => {
      timedOut = true;
      child.kill("SIGKILL");
    }, timeoutMilliseconds);
    child.once("error", reject);
    child.once("close", (status, signal) => {
      clearTimeout(timeout);
      resolve({ status, signal, stderr, timedOut });
    });
  });
}

async function runFIFORegression(kind) {
  const childHome = join(home, `fifo-${kind}`);
  const stateDirectory = join(childHome, "state");
  await mkdir(stateDirectory, { recursive: true });
  const sessionID = `${kind}-fifo`;
  const safeID = Buffer.from(sessionID).toString("base64url");
  const prefix = kind === "opencode" ? "opencode" : "pi";
  const destination = join(stateDirectory, `${prefix}-${safeID}.json`);
  const resourceURL = new URL(
    kind === "opencode"
      ? "../../Sources/MoongladeCore/Resources/opencode/moonglade.js"
      : "../../Sources/MoongladeCore/Resources/pi/moonglade.ts",
    import.meta.url,
  ).href;
  const driverURL = join(home, `fifo-${kind}.mjs`);
  await writeFile(driverURL, `
    import { readFile } from "node:fs/promises";
    import { spawnSync } from "node:child_process";
    import { setTimeout as delay } from "node:timers/promises";
    const destination = ${JSON.stringify(destination)};
    const fifo = spawnSync("/usr/bin/mkfifo", [destination]);
    if (fifo.status !== 0) process.exit(10);
    let update;
    if (${JSON.stringify(kind)} === "opencode") {
      const { MoongladePlugin } = await import(${JSON.stringify(resourceURL)});
      const plugin = await MoongladePlugin({
        directory: "/tmp/project",
        client: {
          session: { get: async () => ({ data: {} }) },
          app: { log: async () => {} },
        },
      });
      update = plugin.event({ event: {
        type: "session.created",
        properties: { info: { id: ${JSON.stringify(sessionID)}, directory: "/tmp/project" } },
      }});
    } else {
      const { default: moonglade } = await import(${JSON.stringify(resourceURL)});
      const handlers = new Map();
      moonglade({ on: (event, handler) => handlers.set(event, handler) });
      update = handlers.get("session_start")({}, {
        cwd: "/tmp/project",
        sessionManager: { getSessionId: () => ${JSON.stringify(sessionID)} },
      });
    }
    const completed = await Promise.race([
      update.then(() => true),
      delay(300).then(() => false),
    ]);
    if (!completed) process.exit(2);
    JSON.parse(await readFile(destination, "utf8"));
  `);
  return runNodeDriver(driverURL, { MOONGLADE_HOME: childHome });
}

try {
  const { MoongladePlugin } = await import(
    "../../Sources/MoongladeCore/Resources/opencode/moonglade.js"
  );
  const childSessionIDs = new Set();
  const plugin = await MoongladePlugin({
    directory: "/tmp/project",
    client: {
      session: {
        get: async ({ path }) => ({
          data: childSessionIDs.has(path.id) ? { parentID: "root" } : {},
        }),
      },
      app: { log: async ({ body }) => { throw new Error(body.message); } },
    },
  });
  const event = (type, properties) => plugin.event({ event: { type, properties } });
  const readState = async (sessionID) => JSON.parse(await readFile(
    join(home, "state", `opencode-${Buffer.from(sessionID).toString("base64url")}.json`),
    "utf8",
  ));
  // OpenCode can deliver a burst without awaiting previous plugin handlers.
  // The creation event must also be ordered ahead of its status events;
  // message.updated describes persisted message data, not active generation,
  // and must never resurrect a turn after the authoritative idle signal.
  await Promise.all([
    event("session.created", {
      info: { id: "regression", directory: "/tmp/project" },
    }),
    event("session.status", { sessionID: "regression", status: { type: "busy" } }),
    event("session.status", { sessionID: "regression", status: { type: "idle" } }),
    event("message.updated", { sessionID: "regression" }),
  ]);

  const state = await readState("regression");
  assert.equal(state.status, "idle", "busy -> idle -> message.updated must remain idle");
  assert.equal(
    state.terminal.orca_terminal_handle,
    null,
    "a non-Orca OpenCode host must not persist an Orca handle",
  );

  for (const [sessionID, idleType, idleProperties] of [
    ["permission-session-idle", "session.idle", {}],
    ["permission-status-idle", "session.status", { status: { type: "idle" } }],
  ]) {
    await event("session.created", {
      info: { id: sessionID, directory: "/tmp/project" },
    });
    await event("permission.asked", { sessionID });
    await event(idleType, { sessionID, ...idleProperties });

    const pendingState = await readState(sessionID);
    assert.equal(
      pendingState.status,
      "needs_attention",
      `${idleType} must not clear a pending permission`,
    );
    assert.equal(pendingState.attention_reason, "permission");

    await event("permission.replied", { sessionID });
    const repliedState = await readState(sessionID);
    assert.equal(repliedState.status, "working", "permission.replied must clear the alert");
    assert.equal(repliedState.attention_reason, null);

    await event(idleType, { sessionID, ...idleProperties });
    const idleState = await readState(sessionID);
    assert.equal(idleState.status, "idle", `${idleType} must apply after the permission reply`);
  }

  // OpenCode's AskUserQuestion flow mirrors permissions: question.asked
  // blocks the turn until the user answers (question.replied) or dismisses
  // the prompt (question.rejected), and idle noise for the paused turn must
  // not hide the alert.
  for (const [sessionID, resolutionType] of [
    ["question-replied", "question.replied"],
    ["question-rejected", "question.rejected"],
  ]) {
    await event("session.created", {
      info: { id: sessionID, directory: "/tmp/project" },
    });
    await event("question.asked", { sessionID });
    await event("session.status", { sessionID, status: { type: "idle" } });

    const pendingState = await readState(sessionID);
    assert.equal(
      pendingState.status,
      "needs_attention",
      "idle noise must not clear a pending question",
    );
    assert.equal(pendingState.attention_reason, "permission");

    await event(resolutionType, { sessionID });
    const resolvedState = await readState(sessionID);
    assert.equal(resolvedState.status, "working", `${resolutionType} must clear the alert`);
    assert.equal(resolvedState.attention_reason, null);

    await event("session.status", { sessionID, status: { type: "idle" } });
    const idleState = await readState(sessionID);
    assert.equal(
      idleState.status,
      "idle",
      `session.status idle must apply after ${resolutionType}`,
    );
  }

  // Subagents run as child sessions, but their permission and question
  // prompts surface in the root session's terminal: the root must turn red
  // and stay red until every outstanding prompt is answered.
  await event("session.created", {
    info: { id: "orchestrator", directory: "/tmp/project" },
  });
  await event("session.created", {
    info: { id: "worker-a", parentID: "orchestrator", directory: "/tmp/project" },
  });
  await event("session.created", {
    info: { id: "worker-b", parentID: "orchestrator", directory: "/tmp/project" },
  });
  await event("permission.asked", { sessionID: "worker-a", id: "ask-a" });
  const childAskState = await readState("orchestrator");
  assert.equal(
    childAskState.status,
    "needs_attention",
    "a child session's permission prompt must alert the root session",
  );
  assert.equal(childAskState.attention_reason, "permission");

  await event("question.asked", { sessionID: "worker-b", id: "ask-b" });
  await event("session.status", { sessionID: "orchestrator", status: { type: "busy" } });
  await event("permission.replied", { sessionID: "worker-a", requestID: "ask-a" });
  const outstandingAskState = await readState("orchestrator");
  assert.equal(
    outstandingAskState.status,
    "needs_attention",
    "answering one prompt must not clear another child's pending prompt",
  );

  await event("question.replied", { sessionID: "worker-b", requestID: "ask-b" });
  const answeredAsksState = await readState("orchestrator");
  assert.equal(
    answeredAsksState.status,
    "working",
    "answering the last outstanding prompt must clear the alert",
  );
  assert.equal(answeredAsksState.attention_reason, null);

  const childDocuments = (await readdir(join(home, "state"))).filter((name) => (
    name.includes(Buffer.from("worker-a").toString("base64url"))
      || name.includes(Buffer.from("worker-b").toString("base64url"))
  ));
  assert.deepEqual(
    childDocuments,
    [],
    "child sessions must never receive their own state documents",
  );

  await event("permission.asked", { sessionID: "worker-a", id: "ask-c" });
  await event("session.deleted", { sessionID: "worker-a" });
  await event("session.status", { sessionID: "orchestrator", status: { type: "idle" } });
  const abortedChildState = await readState("orchestrator");
  assert.equal(
    abortedChildState.status,
    "idle",
    "a deleted child must release its pending prompts",
  );

  // Daemon restart recovery: a prompt from a child session the plugin has
  // never seen must be re-targeted at its root after the parent lookup.
  await event("session.created", {
    info: { id: "root", directory: "/tmp/project" },
  });
  childSessionIDs.add("restart-child");
  await event("permission.asked", { sessionID: "restart-child", id: "ask-r" });
  const recoveredAskState = await readState("root");
  assert.equal(
    recoveredAskState.status,
    "needs_attention",
    "a prompt from an unknown child must alert its root after the parent lookup",
  );
  await event("permission.replied", { sessionID: "restart-child", requestID: "ask-r" });
  const recoveredReplyState = await readState("root");
  assert.equal(
    recoveredReplyState.status,
    "working",
    "the recovered child's reply must clear the root alert",
  );

  // OpenCode names a session once its first turn is summarized. That title is
  // the only signal that identifies which terminal pane hosts the session, so
  // it has to reach the state document — the app must never have to guess it
  // back from a tab title it shares with unrelated panes.
  await event("session.created", {
    info: { id: "titled", directory: "/tmp/project", title: "Implementar tarea 769" },
  });
  const createdTitleState = await readState("titled");
  assert.equal(
    createdTitleState.session_title,
    "Implementar tarea 769",
    "session.created must persist the session title",
  );

  await event("session.updated", {
    sessionID: "titled",
    info: { id: "titled", directory: "/tmp/project", title: "Revisar matriz de pruebas" },
  });
  const retitledState = await readState("titled");
  assert.equal(
    retitledState.session_title,
    "Revisar matriz de pruebas",
    "session.updated must persist a retitle",
  );
  assert.equal(
    retitledState.status,
    "working",
    "a retitle must not move the session status",
  );

  // A retitle arriving while the turn is blocked must reach the document
  // without answering the prompt on the user's behalf.
  await event("permission.asked", { sessionID: "titled", id: "ask-titled" });
  await event("session.updated", {
    sessionID: "titled",
    info: { id: "titled", directory: "/tmp/project", title: "Título durante el permiso" },
  });
  const blockedRetitleState = await readState("titled");
  assert.equal(
    blockedRetitleState.session_title,
    "Título durante el permiso",
    "a retitle must land while a permission is outstanding",
  );
  assert.equal(
    blockedRetitleState.status,
    "needs_attention",
    "a retitle must not clear a pending permission",
  );
  await event("permission.replied", { sessionID: "titled", requestID: "ask-titled" });

  // Subagents are titled too. Their titles belong to no terminal pane, so a
  // child retitle must not fabricate a state document.
  await event("session.created", {
    info: { id: "titled-child", parentID: "titled", directory: "/tmp/project" },
  });
  await event("session.updated", {
    sessionID: "titled-child",
    info: { id: "titled-child", directory: "/tmp/project", title: "Subagente" },
  });
  assert.equal(
    (await readdir(join(home, "state"))).includes(
      `opencode-${Buffer.from("titled-child").toString("base64url")}.json`,
    ),
    false,
    "a child session retitle must not create a state document",
  );

  await event("session.created", {
    info: { id: "permission-deleted", directory: "/tmp/project" },
  });
  await event("permission.asked", { sessionID: "permission-deleted" });
  await event("session.deleted", { sessionID: "permission-deleted" });
  const deletedState = await readState("permission-deleted");
  assert.equal(deletedState.status, "ended", "session deletion must end a pending permission");
  assert.equal(deletedState.attention_reason, null);

  const tombstonedSessionID = "deleted-with-trailing-status";
  await event("session.created", {
    info: { id: tombstonedSessionID, directory: "/tmp/project" },
  });
  await Promise.all([
    event("session.deleted", { sessionID: tombstonedSessionID }),
    event("session.status", { sessionID: tombstonedSessionID, status: { type: "busy" } }),
  ]);
  const tombstonedState = await readState(tombstonedSessionID);
  assert.equal(
    tombstonedState.status,
    "ended",
    "a status queued behind deletion must not resurrect the session",
  );

  await event("permission.asked", { sessionID: tombstonedSessionID });
  await event("session.status", {
    sessionID: tombstonedSessionID,
    status: { type: "idle" },
  });
  const ignoredNoiseState = await readState(tombstonedSessionID);
  assert.equal(
    ignoredNoiseState.status,
    "ended",
    "later non-created events must remain ignored after deletion",
  );

  await event("session.created", {
    info: { id: tombstonedSessionID, directory: "/tmp/reused-project" },
  });
  const reusedState = await readState(tombstonedSessionID);
  assert.equal(reusedState.status, "working", "explicit creation must permit session ID reuse");
  assert.equal(reusedState.cwd, "/tmp/reused-project");

  const failedEndSessionID = "failed-end-retry";
  const failedEndDestination = join(
    home,
    "state",
    `opencode-${Buffer.from(failedEndSessionID).toString("base64url")}.json`,
  );
  const failedEndWrites = [];
  const failedEndPlugin = await MoongladePlugin({
    directory: "/tmp/project",
    client: {
      session: { get: async () => ({ data: {} }) },
      app: { log: async ({ body }) => { failedEndWrites.push(body.message); } },
    },
  });
  const failedEndEvent = (type, properties) => failedEndPlugin.event({
    event: { type, properties },
  });
  await failedEndEvent("session.created", {
    info: { id: failedEndSessionID, directory: "/tmp/project" },
  });
  await rm(failedEndDestination);
  await mkdir(failedEndDestination);
  await Promise.all([
    failedEndEvent("session.deleted", { sessionID: failedEndSessionID }),
    failedEndEvent("session.status", {
      sessionID: failedEndSessionID,
      status: { type: "busy" },
    }),
  ]);
  assert.equal(
    failedEndWrites.length,
    1,
    "noise after a failed end write must be suppressed rather than attempted",
  );
  await rm(failedEndDestination, { recursive: true });
  await failedEndEvent("session.deleted", { sessionID: failedEndSessionID });
  const retriedEndState = await readState(failedEndSessionID);
  assert.equal(retriedEndState.status, "ended", "session deletion must retry a failed end write");

  await event("session.created", {
    info: { id: "reclassified-root", directory: "/tmp/project" },
  });
  await event("session.deleted", { sessionID: "reclassified-root" });
  childSessionIDs.add("reclassified-root");
  await event("permission.asked", { sessionID: "reclassified-root" });
  const reclassifiedRootState = await readState("reclassified-root");
  assert.equal(
    reclassifiedRootState.status,
    "ended",
    "a deleted root ID reused by a child must not retain root registry state",
  );

  await event("session.created", {
    info: { id: "reclassified-child", parentID: "root", directory: "/tmp/project" },
  });
  await event("session.deleted", { sessionID: "reclassified-child" });
  await event("session.created", {
    info: { id: "reclassified-child", directory: "/tmp/project" },
  });
  const reclassifiedChildState = await readState("reclassified-child");
  assert.equal(
    reclassifiedChildState.status,
    "working",
    "a deleted child ID must be reusable by a root session",
  );

  const runStalledBurst = async (sessionID, events) => {
    let releaseLookup;
    const stalledLookup = new Promise((resolve) => { releaseLookup = resolve; });
    let lookupCount = 0;
    let stalledSignal;
    const stalledPlugin = await MoongladePlugin({
      directory: "/tmp/project",
      client: {
        session: {
          get: async (options) => {
            lookupCount += 1;
            if (lookupCount === 1) {
              stalledSignal = options.signal;
              return stalledLookup;
            }
            return { data: {} };
          },
        },
        app: { log: async () => {} },
      },
    });
    const stalledEvent = (type, properties) => stalledPlugin.event({
      event: { type, properties },
    });
    const originalSetTimeout = globalThis.setTimeout;
    globalThis.setTimeout = (callback, _milliseconds, ...arguments_) => {
      queueMicrotask(() => callback(...arguments_));
      return undefined;
    };
    const stalledHandlers = events.map(({ type, properties }) => (
      stalledEvent(type, { sessionID, ...properties })
    ));
    let handlersCompleted;
    try {
      handlersCompleted = await Promise.race([
        Promise.all(stalledHandlers).then(() => true),
        delay(250).then(() => false),
      ]);
    } finally {
      globalThis.setTimeout = originalSetTimeout;
      releaseLookup({ data: {} });
      await Promise.all(stalledHandlers);
    }
    return { handlersCompleted, lookupCount, stalledSignal };
  };

  const stalledBurst = await runStalledBurst("stalled-burst", [
    { type: "message.updated", properties: {} },
    ...Array.from({ length: 32 }, () => ({ type: "message.updated", properties: {} })),
    { type: "session.status", properties: { status: { type: "idle" } } },
  ]);
  assert.equal(
    stalledBurst.handlersCompleted,
    true,
    "a stalled lookup must not leave same-session event handlers stuck",
  );
  assert.equal(
    stalledBurst.lookupCount,
    2,
    "a burst must retain only one active update plus the latest pending update",
  );
  assert.equal(
    stalledBurst.stalledSignal?.aborted,
    true,
    "the stalled lookup must be cancelled at its deadline",
  );
  const stalledState = await readState("stalled-burst");
  assert.equal(stalledState.status, "idle", "the latest coalesced update must be applied");

  const unansweredPermission = await runStalledBurst("stalled-permission-asked", [
    { type: "message.updated", properties: {} },
    { type: "permission.asked", properties: {} },
    { type: "session.status", properties: { status: { type: "idle" } } },
  ]);
  assert.equal(unansweredPermission.handlersCompleted, true);
  assert.equal(unansweredPermission.lookupCount, 2);
  const unansweredPermissionState = await readState("stalled-permission-asked");
  assert.equal(
    unansweredPermissionState.status,
    "needs_attention",
    "coalescing must not replace an unanswered permission with idle noise",
  );

  const repliedPermission = await runStalledBurst("stalled-permission-replied", [
    { type: "permission.asked", properties: {} },
    { type: "permission.replied", properties: {} },
    { type: "session.status", properties: { status: { type: "idle" } } },
  ]);
  assert.equal(repliedPermission.handlersCompleted, true);
  assert.equal(repliedPermission.lookupCount, 1);
  const repliedPermissionState = await readState("stalled-permission-replied");
  assert.equal(
    repliedPermissionState.status,
    "idle",
    "a coalesced permission reply must allow the later idle transition",
  );

  const unansweredQuestion = await runStalledBurst("stalled-question-asked", [
    { type: "message.updated", properties: {} },
    { type: "question.asked", properties: {} },
    { type: "session.status", properties: { status: { type: "idle" } } },
  ]);
  assert.equal(unansweredQuestion.handlersCompleted, true);
  const unansweredQuestionState = await readState("stalled-question-asked");
  assert.equal(
    unansweredQuestionState.status,
    "needs_attention",
    "coalescing must not replace an unanswered question with idle noise",
  );

  const repliedQuestion = await runStalledBurst("stalled-question-replied", [
    { type: "question.asked", properties: {} },
    { type: "question.replied", properties: {} },
    { type: "session.status", properties: { status: { type: "idle" } } },
  ]);
  assert.equal(repliedQuestion.handlersCompleted, true);
  const repliedQuestionState = await readState("stalled-question-replied");
  assert.equal(
    repliedQuestionState.status,
    "idle",
    "a coalesced question reply must allow the later idle transition",
  );

  const failedWriteSessionID = "failed-write-cleanup";
  const failedWriteSafeID = Buffer.from(failedWriteSessionID).toString("base64url");
  const failedWriteDestination = join(home, "state", `opencode-${failedWriteSafeID}.json`);
  await mkdir(failedWriteDestination);
  const writeFailures = [];
  const failedWritePlugin = await MoongladePlugin({
    directory: "/tmp/project",
    client: {
      session: { get: async () => ({ data: {} }) },
      app: { log: async ({ body }) => { writeFailures.push(body.message); } },
    },
  });
  await failedWritePlugin.event({
    event: {
      type: "session.created",
      properties: {
        info: { id: failedWriteSessionID, directory: "/tmp/project" },
      },
    },
  });
  assert.equal(writeFailures.length, 1, "the destination directory must make rename fail");
  assert.match(writeFailures[0], /rename/, "the original rename failure must be reported");
  const leakedTemporaryFiles = (await readdir(join(home, "state"))).filter((name) => (
    name.startsWith(`.${failedWriteSafeID}-${process.pid}-`) && name.endsWith(".tmp")
  ));
  assert.deepEqual(
    leakedTemporaryFiles,
    [],
    "a failed rename must not leave its unique temporary state file behind",
  );

  const secureReadFailures = [];
  const growingSessionID = "growing-identity";
  const growingDestination = join(
    home,
    "state",
    `opencode-${Buffer.from(growingSessionID).toString("base64url")}.json`,
  );
  await event("session.created", {
    info: { id: growingSessionID, directory: "/tmp/project" },
  });
  const attackerState = await readState(growingSessionID);
  attackerState.process_identity = {
    pid: attackerState.pid,
    kernel_start_time_us: 987654321,
  };
  await writeFile(growingDestination, `${JSON.stringify(attackerState)}\n`, { mode: 0o600 });
  const barrier = pauseStateReadAfterStat(growingDestination);
  const growingUpdate = event("session.idle", { sessionID: growingSessionID });
  const reachedStat = await Promise.race([
    barrier.reached.then(() => true),
    delay(500).then(() => false),
  ]);
  if (!reachedStat) {
    secureReadFailures.push("OpenCode identity read did not reach fstat");
    barrier.resume();
  } else {
    await appendFile(growingDestination, Buffer.alloc(1_048_577, 0x20));
    barrier.resume();
  }
  await growingUpdate;
  const replacedGrowingState = await readState(growingSessionID);
  if (replacedGrowingState.process_identity !== undefined) {
    secureReadFailures.push("OpenCode preserved identity from a document grown past 1 MiB");
  }

  const { default: moonglade } = await import(
    "../../Sources/MoongladeCore/Resources/pi/moonglade.ts"
  );
  const piHandlers = new Map();
  moonglade({ on: (name, handler) => piHandlers.set(name, handler) });
  const piSessionID = "pi-growing-identity";
  const piContext = {
    cwd: "/tmp/project",
    sessionManager: { getSessionId: () => piSessionID },
  };
  const piDestination = join(
    home,
    "state",
    `pi-${Buffer.from(piSessionID).toString("base64url")}.json`,
  );
  await piHandlers.get("session_start")({}, piContext);
  const piAttackerState = JSON.parse(await readFile(piDestination, "utf8"));
  assert.equal(
    piAttackerState.terminal.orca_terminal_handle,
    null,
    "a non-Orca Pi host must not persist an Orca handle",
  );
  piAttackerState.process_identity = {
    pid: piAttackerState.pid,
    kernel_start_time_us: 987654321,
  };
  await writeFile(piDestination, `${JSON.stringify(piAttackerState)}\n`, { mode: 0o600 });
  const piBarrier = pauseStateReadAfterStat(piDestination);
  const piGrowingUpdate = piHandlers.get("input")({}, piContext);
  const piReachedStat = await Promise.race([
    piBarrier.reached.then(() => true),
    delay(500).then(() => false),
  ]);
  if (!piReachedStat) {
    secureReadFailures.push("Pi identity read did not reach fstat");
    piBarrier.resume();
  } else {
    await appendFile(piDestination, Buffer.alloc(1_048_577, 0x20));
    piBarrier.resume();
  }
  await piGrowingUpdate;
  const replacedPiState = JSON.parse(await readFile(piDestination, "utf8"));
  if (replacedPiState.process_identity !== undefined) {
    secureReadFailures.push("Pi preserved identity from a document grown past 1 MiB");
  }

  for (const kind of ["opencode", "pi"]) {
    const result = await runFIFORegression(kind);
    if (result.timedOut || result.status !== 0) {
      secureReadFailures.push(
        `${kind} FIFO read blocked or failed: status=${result.status} signal=${result.signal}`
          + ` stderr=${result.stderr}`,
      );
    }
  }
  assert.deepEqual(secureReadFailures, [], "integration secure-read regressions");

  console.log("OpenCode plugin regression tests passed");
} finally {
  await rm(home, { recursive: true, force: true });
}
