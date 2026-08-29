#!/usr/bin/env node
// Parse an agent task from a GitHub Issue body or workflow_dispatch inputs.
//
// Normalized payload:
//   task_id, target_repository, source, title, prompt, created_at,
//   requested_model, max_runtime, dry_run, runner_mode

import fs from "node:fs";
import path from "node:path";

const REQUIRED = ["task_id", "target_repository", "title", "prompt"];
const MAX_TASK_ID = 128;
const MAX_TARGET_REPOSITORY = 200;
const MAX_TITLE = 200;
const MAX_PROMPT_BYTES = 65536;
const MAX_MODEL = 256;
const MAX_RUNTIME_MINUTES = 45;

function die(message) {
  process.stderr.write(`INVALID_PAYLOAD: ${message}\n`);
  process.exit(1);
}

function extractJson(body) {
  const text = String(body ?? "");
  const trimmed = text.trim();
  if (!trimmed) die("task body is empty");
  try {
    return JSON.parse(trimmed);
  } catch {
    const fence = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/);
    if (fence) {
      try { return JSON.parse(fence[1]); } catch {}
    }
    const line = trimmed.split("\n").find((l) => l.trim().startsWith("{"));
    if (line) {
      try { return JSON.parse(line); } catch {}
    }
  }
  die("could not parse a JSON task payload from the body");
}

function requireString(value, field) {
  if (typeof value !== "string") die(`${field} must be a string`);
  return value;
}

function normalizeSingleLine(value, field, maxLength) {
  const text = requireString(value, field).trim();
  if (!text) die(`missing required field: ${field}`);
  if (text.length > maxLength) die(`${field} is too long`);
  if (/[\u0000-\u001f\u007f]/u.test(text)) die(`${field} must be a single printable line`);
  return text;
}

function normalizeTaskId(value) {
  const taskId = normalizeSingleLine(value, "task_id", MAX_TASK_ID);
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/u.test(taskId) || taskId.endsWith(".") || taskId.endsWith(".lock") || taskId.includes("..")) {
    die("task_id contains unsafe branch-name characters");
  }
  return taskId;
}

function normalizeTargetRepository(value) {
  const repository = normalizeSingleLine(value, "target_repository", MAX_TARGET_REPOSITORY);
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u.test(repository)) {
    die("target_repository must be owner/name");
  }
  return repository;
}

function normalizeTitle(value) {
  return normalizeSingleLine(value, "title", MAX_TITLE);
}

function normalizePrompt(value) {
  const prompt = requireString(value, "prompt").trim();
  if (!prompt) die("missing required field: prompt");
  if (prompt.includes("\u0000")) die("prompt must not contain NUL bytes");
  if (Buffer.byteLength(prompt, "utf8") > MAX_PROMPT_BYTES) die("prompt is too large");
  return prompt;
}

function normalizeRequestedModel(raw) {
  const requested = raw.requested_model;
  const dispatchModel = raw.model;
  if (requested !== undefined && requested !== null && requested !== "" &&
      dispatchModel !== undefined && dispatchModel !== null && dispatchModel !== "" &&
      String(requested) !== String(dispatchModel)) {
    die("requested_model and model disagree");
  }
  const value = requested !== undefined && requested !== null && requested !== "" ? requested : dispatchModel;
  if (value === undefined || value === null || value === "") return "";
  const model = normalizeSingleLine(value, "requested_model", MAX_MODEL);
  if (!/^[A-Za-z0-9._:/@+-]+$/u.test(model)) die("requested_model contains unsupported characters");
  return model;
}

function normalizeMaxRuntime(value) {
  if (value === undefined || value === null || value === "") return "";
  if (typeof value !== "string" && typeof value !== "number") die("max_runtime must be an integer number of minutes");
  const text = String(value).trim();
  if (!/^[0-9]+$/u.test(text)) die("max_runtime must be an integer number of minutes");
  const minutes = Number(text);
  if (!Number.isSafeInteger(minutes) || minutes < 1 || minutes > MAX_RUNTIME_MINUTES) {
    die(`max_runtime must be between 1 and ${MAX_RUNTIME_MINUTES} minutes`);
  }
  return String(minutes);
}

function normalizeBoolean(value) {
  if (value === true || value === "true") return true;
  if (value === false || value === "false" || value === undefined || value === null || value === "") return false;
  die("dry_run must be true or false");
}

function normalizeRunnerMode(value) {
  if (value === undefined || value === null || String(value).trim() === "") return "self-hosted";
  if (typeof value !== "string") die("runner_mode must be github or self-hosted");
  const mode = value.trim();
  if (mode === "github" || mode === "self-hosted") return mode;
  die("runner_mode must be github or self-hosted");
}

function normalizeAgent(value) {
  if (value === undefined || value === null || String(value).trim() === "") return "opencode";
  if (typeof value !== "string") die("agent must be opencode, codex, or claude-code");
  const agent = value.trim().toLowerCase();
  if (!["opencode", "codex", "claude-code"].includes(agent)) {
    die("agent must be opencode, codex, or claude-code");
  }
  return agent;
}

function normalize(raw, source) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) die("payload must be a JSON object");
  for (const field of REQUIRED) {
    if (raw[field] === undefined || raw[field] === null) die(`missing required field: ${field}`);
  }

  const taskId = normalizeTaskId(raw.task_id);
  const targetRepository = normalizeTargetRepository(raw.target_repository);
  const title = normalizeTitle(raw.title);
  const prompt = normalizePrompt(raw.prompt);
  const requestedModel = normalizeRequestedModel(raw);
  const maxRuntime = normalizeMaxRuntime(raw.max_runtime);
  const dryRun = normalizeBoolean(raw.dry_run);
  const runnerMode = normalizeRunnerMode(raw.runner_mode);
  if (runnerMode === "github" && !dryRun) {
    die("runner_mode=github is dry-run only; agent execution requires self-hosted isolation");
  }

  return {
    task_id: taskId,
    target_repository: targetRepository,
    source,
    title,
    prompt,
    created_at: new Date().toISOString(),
    requested_model: requestedModel,
    max_runtime: maxRuntime,
    dry_run: dryRun,
    runner_mode: runnerMode,
    agent: normalizeAgent(raw.agent),
  };
}

function main() {
  const runnerTemp = process.env.RUNNER_TEMP;
  if (!runnerTemp) die("RUNNER_TEMP is not set");
  const outPath = path.join(runnerTemp, "task.json");

  let payload;
  let source;
  const dispatchInputs = process.env.DISPATCH_INPUTS;
  if (dispatchInputs && dispatchInputs.trim() !== "") {
    let raw;
    try { raw = JSON.parse(dispatchInputs); } catch { die("DISPATCH_INPUTS is not valid JSON"); }
    source = "workflow_dispatch";
    payload = normalize(raw, source);
  } else {
    const eventPath = process.env.EVENT_PATH;
    if (!eventPath) die("neither EVENT_PATH nor DISPATCH_INPUTS provided");
    let event;
    try { event = JSON.parse(fs.readFileSync(eventPath, "utf8")); } catch { die("EVENT_PATH is not readable JSON"); }
    const issue = event.issue;
    if (!issue || !issue.number) die("event has no issue payload");
    payload = normalize(extractJson(issue.body), `issue#${issue.number}`);
  }

  fs.writeFileSync(outPath, JSON.stringify(payload, null, 2));
  const outFile = process.env.GITHUB_OUTPUT;
  if (outFile) {
    const lines = [
      `task_id=${payload.task_id}`,
      `target_repository=${payload.target_repository}`,
      `title=${payload.title}`,
      `source=${payload.source}`,
      `requested_model=${payload.requested_model}`,
      `max_runtime=${payload.max_runtime}`,
      `dry_run=${payload.dry_run}`,
      `runner_mode=${payload.runner_mode}`,
      `agent=${payload.agent}`,
    ];
    fs.appendFileSync(outFile, "\n" + lines.join("\n") + "\n");
  }
  process.stdout.write(`task_id=${payload.task_id} target_repository=${payload.target_repository} source=${payload.source} dry_run=${payload.dry_run} runner_mode=${payload.runner_mode} agent=${payload.agent}\n`);
}

main();
