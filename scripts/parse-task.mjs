#!/usr/bin/env node
// Parse an agent task from a GitHub Issue body or workflow_dispatch inputs.
//
// Normalized payload:
//   task_id, target_repository, source, title, prompt, created_at,
//   requested_model, max_runtime, dry_run, runner_mode

import fs from "node:fs";
import path from "node:path";

const REQUIRED = ["task_id", "target_repository", "title", "prompt"];

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

function normalizeBoolean(value) {
  if (value === true || value === "true") return true;
  if (value === false || value === "false" || value === undefined || value === null || value === "") return false;
  die("dry_run must be true or false");
}

function normalizeRunnerMode(value) {
  if (value === undefined || value === null || String(value).trim() === "") return "github";
  const mode = String(value).trim();
  if (mode === "github" || mode === "self-hosted") return mode;
  die("runner_mode must be github or self-hosted");
}

function normalize(raw, source) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) die("payload must be a JSON object");
  for (const field of REQUIRED) {
    const v = raw[field];
    if (v === undefined || v === null || String(v).trim() === "") die(`missing required field: ${field}`);
  }
  const prompt = String(raw.prompt).trim();
  if (!prompt) die("missing required field: prompt");
  return {
    task_id: String(raw.task_id).trim(),
    target_repository: String(raw.target_repository).trim(),
    source,
    title: String(raw.title).trim(),
    prompt,
    created_at: new Date().toISOString(),
    requested_model: raw.requested_model ? String(raw.requested_model) : "",
    max_runtime: raw.max_runtime ? String(raw.max_runtime) : "",
    dry_run: normalizeBoolean(raw.dry_run),
    runner_mode: normalizeRunnerMode(raw.runner_mode),
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
    ];
    fs.appendFileSync(outFile, "\n" + lines.join("\n") + "\n");
  }
  process.stdout.write(`task_id=${payload.task_id} target_repository=${payload.target_repository} source=${payload.source} dry_run=${payload.dry_run} runner_mode=${payload.runner_mode}\n`);
}

main();
