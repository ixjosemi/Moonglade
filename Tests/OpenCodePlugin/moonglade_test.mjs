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
      const { createSessionTracker } = await import(${JSON.stringify(resourceURL)});
      const tracker = createSessionTracker({
        directory: "/tmp/project",
        lookupSession: async () => undefined,
        reportError: () => {},
      });
      update = tracker.receive({
        type: "session.created",
        data: {
          sessionID: ${JSON.stringify(sessionID)},
          location: { directory: "/tmp/project" },
        },
      });
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
  const pluginModule = await import(
    "../../Sources/MoongladeCore/Resources/opencode/moonglade.js"
  );
  const { createSessionTracker } = pluginModule;

  // OpenCode 2 never calls a V1 plugin: it loads only a default export that
  // carries an id and a setup(ctx) entry point.
  assert.equal(
    pluginModule.MoongladePlugin,
    undefined,
    "the V1 named plugin export must be gone",
  );
  assert.equal(pluginModule.default?.id, "moonglade.opencode", "V2 plugin id");
  assert.equal(typeof pluginModule.default?.setup, "function", "V2 plugin setup");

  const project = { directory: "/tmp/project" };
  const sessionInfo = (sessionID, extra = {}) => ({
    id: sessionID,
    projectID: "global",
    location: project,
    ...extra,
  });
  const created = (sessionID, extra = {}) => ({
    type: "session.created",
    data: { sessionID, projectID: "global", location: project, slug: sessionID, ...extra },
  });

  // setup(ctx) subscribes to the server event stream and stops on cleanup.
  const setupHome = "/tmp/setup-project";
  let releaseStream;
  let subscribedSignal;
  const setupCleanup = await pluginModule.default.setup({
    location: { directory: setupHome },
    session: { get: async ({ sessionID }) => sessionInfo(sessionID) },
    event: {
      subscribe: async function* ({ signal }) {
        subscribedSignal = signal;
        yield {
          type: "session.created",
          data: { sessionID: "setup-session", location: { directory: setupHome }, slug: "s" },
        };
        await new Promise((resolve) => { releaseStream = resolve; });
      },
    },
  });
  assert.equal(typeof setupCleanup, "function", "setup must return a cleanup function");
  const setupStatePath = join(
    home,
    "state",
    `opencode-${Buffer.from("setup-session").toString("base64url")}.json`,
  );
  let setupState;
  for (let attempt = 0; attempt < 50 && !setupState; attempt += 1) {
    try {
      setupState = JSON.parse(await readFile(setupStatePath, "utf8"));
    } catch {
      await delay(10);
    }
  }
  assert.equal(setupState?.status, "working", "a streamed session.created must write state");
  assert.equal(setupState.cwd, setupHome);
  setupCleanup();
  assert.equal(subscribedSignal?.aborted, true, "cleanup must abort the event subscription");
  releaseStream();

  // A stream the service closes on its own leaves the plugin deaf; say so.
  const streamFailures = [];
  pluginModule.default.setup({
    location: { directory: setupHome },
    session: { get: async ({ sessionID }) => sessionInfo(sessionID) },
    event: { subscribe: async function* () {} },
  }, (error) => streamFailures.push(String(error)));
  pluginModule.default.setup({
    location: { directory: setupHome },
    session: { get: async ({ sessionID }) => sessionInfo(sessionID) },
    event: { subscribe: async function* () { throw new Error("stream broke"); } },
  }, (error) => streamFailures.push(String(error)));
  await delay(20);
  assert.deepEqual(
    streamFailures.sort(),
    ["Error: OpenCode event stream ended", "Error: stream broke"],
    "an ended or failed event stream must be reported",
  );

  const childSessionIDs = new Set();
  const tracker = createSessionTracker({
    directory: "/tmp/project",
    lookupSession: async (sessionID) => sessionInfo(
      sessionID,
      childSessionIDs.has(sessionID) ? { parentID: "root" } : {},
    ),
    reportError: (error) => { throw error; },
  });
  const event = (type, data) => tracker.receive({ type, data });
  const create = (sessionID, extra) => tracker.receive(created(sessionID, extra));
  const readState = async (sessionID) => JSON.parse(await readFile(
    join(home, "state", `opencode-${Buffer.from(sessionID).toString("base64url")}.json`),
    "utf8",
  ));
  const hasState = async (sessionID) => (await readdir(join(home, "state"))).includes(
    `opencode-${Buffer.from(sessionID).toString("base64url")}.json`,
  );
  // OpenCode can deliver a burst without awaiting previous plugin handlers.
  // The creation event must also be ordered ahead of its execution events;
  // streamed text describes output, not active generation, and must never
  // resurrect a turn after the authoritative end-of-execution signal.
  await Promise.all([
    create("regression"),
    event("session.execution.started", { sessionID: "regression" }),
    event("session.execution.succeeded", { sessionID: "regression" }),
    event("session.text.delta", { sessionID: "regression", delta: "OK" }),
  ]);

  const state = await readState("regression");
  assert.equal(state.status, "idle", "started -> succeeded -> text delta must remain idle");
  assert.equal(state.schema_version, 1);
  assert.equal(state.tool, "opencode");
  assert.equal(state.cwd, "/tmp/project");
  assert.equal(
    state.terminal.orca_terminal_handle,
    null,
    "a non-Orca OpenCode host must not persist an Orca handle",
  );

  for (const endType of ["session.execution.failed", "session.execution.interrupted"]) {
    const sessionID = `ended-by-${endType}`;
    await create(sessionID);
    await event("session.execution.started", { sessionID });
    await event(endType, { sessionID });
    assert.equal((await readState(sessionID)).status, "idle", `${endType} must end the turn`);
  }

  for (const [sessionID, idleType] of [
    ["permission-succeeded", "session.execution.succeeded"],
    ["permission-interrupted", "session.execution.interrupted"],
  ]) {
    await create(sessionID);
    await event("permission.asked", { sessionID, id: `${sessionID}-ask` });
    await event(idleType, { sessionID });

    const pendingState = await readState(sessionID);
    assert.equal(
      pendingState.status,
      "needs_attention",
      `${idleType} must not clear a pending permission`,
    );
    assert.equal(pendingState.attention_reason, "permission");

    await event("permission.replied", { sessionID, requestID: `${sessionID}-ask` });
    const repliedState = await readState(sessionID);
    assert.equal(repliedState.status, "working", "permission.replied must clear the alert");
    assert.equal(repliedState.attention_reason, null);

    await event(idleType, { sessionID });
    const idleState = await readState(sessionID);
    assert.equal(idleState.status, "idle", `${idleType} must apply after the permission reply`);
  }

  // OpenCode 2 asks the user questions through forms: form.created blocks
  // the turn until the user answers (form.replied) or dismisses it
  // (form.cancelled), and end-of-turn noise must not hide the alert.
  for (const [sessionID, resolutionType] of [
    ["form-replied", "form.replied"],
    ["form-cancelled", "form.cancelled"],
  ]) {
    await create(sessionID);
    await event("form.created", { form: { id: `${sessionID}-form`, sessionID, title: "Q" } });
    await event("session.execution.succeeded", { sessionID });

    const pendingState = await readState(sessionID);
    assert.equal(
      pendingState.status,
      "needs_attention",
      "end-of-turn noise must not clear a pending form",
    );
    assert.equal(pendingState.attention_reason, "permission");

    await event(resolutionType, { sessionID, id: `${sessionID}-form` });
    const resolvedState = await readState(sessionID);
    assert.equal(resolvedState.status, "working", `${resolutionType} must clear the alert`);
    assert.equal(resolvedState.attention_reason, null);

    await event("session.execution.succeeded", { sessionID });
    const idleState = await readState(sessionID);
    assert.equal(idleState.status, "idle", `the turn end must apply after ${resolutionType}`);
  }

  // Subagents run as child sessions, but their permission and form prompts
  // surface in the root session's terminal: the root must turn red and stay
  // red until every outstanding prompt is answered.
  await create("orchestrator");
  await create("worker-a", { parentID: "orchestrator" });
  await create("worker-b", { parentID: "orchestrator" });
  await event("permission.asked", { sessionID: "worker-a", id: "ask-a" });
  const childAskState = await readState("orchestrator");
  assert.equal(
    childAskState.status,
    "needs_attention",
    "a child session's permission prompt must alert the root session",
  );
  assert.equal(childAskState.attention_reason, "permission");

  await event("form.created", { form: { id: "ask-b", sessionID: "worker-b", title: "Q" } });
  await event("session.execution.started", { sessionID: "orchestrator" });
  await event("permission.replied", { sessionID: "worker-a", requestID: "ask-a" });
  const outstandingAskState = await readState("orchestrator");
  assert.equal(
    outstandingAskState.status,
    "needs_attention",
    "answering one prompt must not clear another child's pending prompt",
  );

  await event("form.replied", { sessionID: "worker-b", id: "ask-b" });
  const answeredAsksState = await readState("orchestrator");
  assert.equal(
    answeredAsksState.status,
    "working",
    "answering the last outstanding prompt must clear the alert",
  );
  assert.equal(answeredAsksState.attention_reason, null);

  assert.equal(await hasState("worker-a"), false, "child sessions never get documents");
  assert.equal(await hasState("worker-b"), false, "child sessions never get documents");

  await event("permission.asked", { sessionID: "worker-a", id: "ask-c" });
  await event("session.deleted", { sessionID: "worker-a" });
  await event("session.execution.succeeded", { sessionID: "orchestrator" });
  const abortedChildState = await readState("orchestrator");
  assert.equal(
    abortedChildState.status,
    "idle",
    "a deleted child must release its pending prompts",
  );

  // The shared OpenCode service can start this plugin after a session began,
  // so its session.created never arrives. A prompt from a child session the
  // plugin has never seen must be re-targeted at its root after the lookup.
  await create("root");
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

  // An unknown root session is rebuilt from the server's session record:
  // its title and working directory come from the lookup, not guesses.
  const lateTracker = createSessionTracker({
    directory: "/tmp/project",
    lookupSession: async (sessionID) => sessionInfo(sessionID, {
      title: "Sesión ya empezada",
      subpath: "packages/app",
    }),
    reportError: (error) => { throw error; },
  });
  await lateTracker.receive({
    type: "session.execution.started",
    data: { sessionID: "late-root" },
  });
  const lateState = await readState("late-root");
  assert.equal(lateState.status, "working", "an unknown root's turn start must write state");
  assert.equal(lateState.session_title, "Sesión ya empezada");
  assert.equal(lateState.cwd, "/tmp/project/packages/app");

  // OpenCode names a session once its first turn is summarized. That title is
  // the only signal that identifies which terminal pane hosts the session, so
  // it has to reach the state document — the app must never have to guess it
  // back from a tab title it shares with unrelated panes.
  await create("titled", { title: "Implementar tarea 769" });
  const createdTitleState = await readState("titled");
  assert.equal(
    createdTitleState.session_title,
    "Implementar tarea 769",
    "session.created must persist the session title",
  );

  await event("session.renamed", { sessionID: "titled", title: "Revisar matriz de pruebas" });
  const retitledState = await readState("titled");
  assert.equal(
    retitledState.session_title,
    "Revisar matriz de pruebas",
    "session.renamed must persist a retitle",
  );
  assert.equal(retitledState.status, "working", "a retitle must not move the session status");

  // A retitle arriving while the turn is blocked must reach the document
  // without answering the prompt on the user's behalf.
  await event("permission.asked", { sessionID: "titled", id: "ask-titled" });
  await event("session.renamed", { sessionID: "titled", title: "Título durante el permiso" });
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
  await create("titled-child", { parentID: "titled" });
  await event("session.renamed", { sessionID: "titled-child", title: "Subagente" });
  assert.equal(
    await hasState("titled-child"),
    false,
    "a child session retitle must not create a state document",
  );

  // A retitle is metadata, not evidence anyone is running the session.
  await event("session.renamed", { sessionID: "archived-unknown", title: "Archivada" });
  assert.equal(
    await hasState("archived-unknown"),
    false,
    "a retitle of an untracked session must not create a state document",
  );

  // OpenCode 2 runs one plugin instance per project location inside a shared
  // service, and every instance sees every location's events. Only the
  // instance for the session's own location may write its document.
  let foreignLookups = 0;
  const foreignTracker = createSessionTracker({
    directory: "/tmp/other-project",
    lookupSession: async (sessionID) => {
      foreignLookups += 1;
      return sessionInfo(sessionID);
    },
    reportError: (error) => { throw error; },
  });
  await foreignTracker.receive(created("foreign-created"));
  await foreignTracker.receive({
    type: "session.execution.started",
    data: { sessionID: "foreign-created" },
  });
  assert.equal(
    await hasState("foreign-created"),
    false,
    "another location's session must not get a document from this instance",
  );
  for (const type of ["session.execution.started", "permission.asked", "session.execution.succeeded"]) {
    await foreignTracker.receive({ type, data: { sessionID: "foreign-unknown", id: "x" } });
  }
  assert.equal(await hasState("foreign-unknown"), false);
  assert.equal(foreignLookups, 1, "a session found foreign must not be looked up again");

  // A foreign subagent is ignored outright, never mapped to a root here.
  await foreignTracker.receive(created("foreign-child", { parentID: "foreign-parent" }));
  await foreignTracker.receive({
    type: "permission.asked",
    data: { sessionID: "foreign-child", id: "fc" },
  });
  assert.equal(await hasState("foreign-parent"), false);
  assert.equal(foreignLookups, 1, "a foreign child must not trigger a lookup");

  // A prompt from an unknown child whose lookup reports another location.
  const childLookupTracker = createSessionTracker({
    directory: "/tmp/other-project",
    lookupSession: async (sessionID) => sessionInfo(sessionID, { parentID: "foreign-root" }),
    reportError: (error) => { throw error; },
  });
  await childLookupTracker.receive({
    type: "permission.asked",
    data: { sessionID: "foreign-unknown-child", id: "fuc" },
  });
  assert.equal(await hasState("foreign-root"), false);
  assert.equal(await hasState("foreign-unknown-child"), false);

  // When the lookup fails, no instance can prove ownership, so none writes;
  // once it answers, only the owner does.
  let lookupWorks = false;
  const flakyLookup = async (sessionID) => {
    if (!lookupWorks) throw new Error("service busy");
    return sessionInfo(sessionID, { title: "Recuperada" });
  };
  const ownerTracker = createSessionTracker({
    directory: "/tmp/project",
    lookupSession: flakyLookup,
    reportError: (error) => { throw error; },
  });
  const bystanderTracker = createSessionTracker({
    directory: "/tmp/other-project",
    lookupSession: flakyLookup,
    reportError: (error) => { throw error; },
  });
  const unowned = { type: "session.execution.started", data: { sessionID: "flaky-lookup" } };
  await Promise.all([ownerTracker.receive(unowned), bystanderTracker.receive(unowned)]);
  assert.equal(await hasState("flaky-lookup"), false, "a failed lookup must write nothing");
  lookupWorks = true;
  await bystanderTracker.receive(unowned);
  assert.equal(await hasState("flaky-lookup"), false, "the bystander must never write");
  await ownerTracker.receive(unowned);
  const recoveredState = await readState("flaky-lookup");
  assert.equal(recoveredState.status, "working", "the owner must write once the lookup answers");
  assert.equal(recoveredState.cwd, "/tmp/project");

  await create("permission-deleted");
  await event("permission.asked", { sessionID: "permission-deleted" });
  await event("session.deleted", { sessionID: "permission-deleted" });
  const deletedState = await readState("permission-deleted");
  assert.equal(deletedState.status, "ended", "session deletion must end a pending permission");
  assert.equal(deletedState.attention_reason, null);

  const tombstonedSessionID = "deleted-with-trailing-status";
  await create(tombstonedSessionID);
  await Promise.all([
    event("session.deleted", { sessionID: tombstonedSessionID }),
    event("session.execution.started", { sessionID: tombstonedSessionID }),
  ]);
  const tombstonedState = await readState(tombstonedSessionID);
  assert.equal(
    tombstonedState.status,
    "ended",
    "an execution event queued behind deletion must not resurrect the session",
  );

  await event("permission.asked", { sessionID: tombstonedSessionID });
  await event("session.execution.succeeded", { sessionID: tombstonedSessionID });
  const ignoredNoiseState = await readState(tombstonedSessionID);
  assert.equal(
    ignoredNoiseState.status,
    "ended",
    "later non-created events must remain ignored after deletion",
  );

  await create(tombstonedSessionID, { subpath: "reused" });
  const reusedState = await readState(tombstonedSessionID);
  assert.equal(reusedState.status, "working", "explicit creation must permit session ID reuse");
  assert.equal(reusedState.cwd, "/tmp/project/reused");

  const failedEndSessionID = "failed-end-retry";
  const failedEndDestination = join(
    home,
    "state",
    `opencode-${Buffer.from(failedEndSessionID).toString("base64url")}.json`,
  );
  const failedEndWrites = [];
  const failedEndTracker = createSessionTracker({
    directory: "/tmp/project",
    lookupSession: async (sessionID) => sessionInfo(sessionID),
    reportError: (error) => { failedEndWrites.push(String(error)); },
  });
  const failedEndEvent = (type, data) => failedEndTracker.receive({ type, data });
  await failedEndTracker.receive(created(failedEndSessionID));
  await rm(failedEndDestination);
  await mkdir(failedEndDestination);
  await Promise.all([
    failedEndEvent("session.deleted", { sessionID: failedEndSessionID }),
    failedEndEvent("session.execution.started", { sessionID: failedEndSessionID }),
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

  await create("reclassified-root");
  await event("session.deleted", { sessionID: "reclassified-root" });
  childSessionIDs.add("reclassified-root");
  await event("permission.asked", { sessionID: "reclassified-root" });
  const reclassifiedRootState = await readState("reclassified-root");
  assert.equal(
    reclassifiedRootState.status,
    "ended",
    "a deleted root ID reused by a child must not retain root registry state",
  );

  await create("reclassified-child", { parentID: "root" });
  await event("session.deleted", { sessionID: "reclassified-child" });
  await create("reclassified-child");
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
    const stalledTracker = createSessionTracker({
      directory: "/tmp/project",
      lookupSession: async (id) => {
        lookupCount += 1;
        if (lookupCount === 1) return stalledLookup;
        return sessionInfo(id);
      },
      reportError: () => {},
    });
    // Expire only the stalled lookup's deadline at once; later lookups get
    // their real deadline so a prompt answer can still prove ownership.
    const originalSetTimeout = globalThis.setTimeout;
    let expiredDeadlines = 0;
    globalThis.setTimeout = (callback, milliseconds, ...arguments_) => {
      if (expiredDeadlines > 0) return originalSetTimeout(callback, milliseconds, ...arguments_);
      expiredDeadlines += 1;
      queueMicrotask(() => callback(...arguments_));
      return undefined;
    };
    const stalledHandlers = events.map(({ type, data }) => (
      stalledTracker.receive({ type, data: { sessionID, ...data } })
    ));
    let handlersCompleted;
    try {
      handlersCompleted = await Promise.race([
        Promise.all(stalledHandlers).then(() => true),
        delay(250).then(() => false),
      ]);
    } finally {
      globalThis.setTimeout = originalSetTimeout;
      releaseLookup(sessionInfo(sessionID));
      await Promise.all(stalledHandlers);
    }
    return { handlersCompleted, lookupCount };
  };

  const textDelta = { type: "session.text.delta", data: { delta: "…" } };
  const turnEnd = { type: "session.execution.succeeded", data: {} };
  const stalledBurst = await runStalledBurst("stalled-burst", [
    textDelta,
    ...Array.from({ length: 32 }, () => textDelta),
    turnEnd,
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
  const stalledState = await readState("stalled-burst");
  assert.equal(stalledState.status, "idle", "the latest coalesced update must be applied");

  for (const [sessionID, ask, resolution, label] of [
    [
      "stalled-permission",
      { type: "permission.asked", data: { id: "p" } },
      { type: "permission.replied", data: { requestID: "p" } },
      "permission",
    ],
    [
      "stalled-form",
      { type: "form.created", data: { form: { id: "f", sessionID: "stalled-form" } } },
      { type: "form.replied", data: { id: "f" } },
      "form",
    ],
  ]) {
    const unanswered = await runStalledBurst(`${sessionID}-asked`, [
      textDelta,
      ask.type === "form.created"
        ? { type: ask.type, data: { form: { ...ask.data.form, sessionID: `${sessionID}-asked` } } }
        : ask,
      turnEnd,
    ]);
    assert.equal(unanswered.handlersCompleted, true);
    assert.equal(unanswered.lookupCount, 2);
    assert.equal(
      (await readState(`${sessionID}-asked`)).status,
      "needs_attention",
      `coalescing must not replace an unanswered ${label} with turn-end noise`,
    );

    const replied = await runStalledBurst(`${sessionID}-replied`, [
      ask.type === "form.created"
        ? { type: ask.type, data: { form: { ...ask.data.form, sessionID: `${sessionID}-replied` } } }
        : ask,
      resolution,
      turnEnd,
    ]);
    assert.equal(replied.handlersCompleted, true);
    assert.equal(
      replied.lookupCount,
      2,
      "a stalled lookup writes nothing, so the coalesced follow-up must retry it",
    );
    assert.equal(
      (await readState(`${sessionID}-replied`)).status,
      "idle",
      `a coalesced ${label} reply must allow the later turn end`,
    );
  }

  const failedWriteSessionID = "failed-write-cleanup";
  const failedWriteSafeID = Buffer.from(failedWriteSessionID).toString("base64url");
  const failedWriteDestination = join(home, "state", `opencode-${failedWriteSafeID}.json`);
  await mkdir(failedWriteDestination);
  const writeFailures = [];
  const failedWriteTracker = createSessionTracker({
    directory: "/tmp/project",
    lookupSession: async (sessionID) => sessionInfo(sessionID),
    reportError: (error) => { writeFailures.push(String(error)); },
  });
  await failedWriteTracker.receive(created(failedWriteSessionID));
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
  await create(growingSessionID);
  const attackerState = await readState(growingSessionID);
  attackerState.process_identity = {
    pid: attackerState.pid,
    kernel_start_time_us: 987654321,
  };
  await writeFile(growingDestination, `${JSON.stringify(attackerState)}\n`, { mode: 0o600 });
  const barrier = pauseStateReadAfterStat(growingDestination);
  const growingUpdate = event("session.execution.succeeded", {
    sessionID: growingSessionID,
  });
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
