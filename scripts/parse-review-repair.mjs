#!/usr/bin/env node
// Validate one pull-request review against dispatcher-owned task metadata.
// PR/review/comment bodies are data only and are never evaluated or logged.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const env = process.env;
const outFile = env.GITHUB_OUTPUT;
const runnerTemp = env.RUNNER_TEMP;
const taskFile = env.TASK_FILE || (runnerTemp && path.join(runnerTemp, "task.json"));

function canonicalRepo(value) {
  return String(value ?? "")
    .replace(/^https?:\/\/github\.com\//i, "")
    .replace(/^git@github\.com:/i, "")
    .replace(/\.git$/i, "")
    .replace(/\/$/, "")
    .toLowerCase();
}

function writeOutput(values) {
  if (!outFile) return;
  fs.appendFileSync(outFile, Object.entries(values).map(([k, v]) => `${k}=${v}`).join("\n") + "\n");
}

function setFailure(category) {
  if (runnerTemp) fs.writeFileSync(path.join(runnerTemp, "failure_category"), `${category}\n`);
}

function fail(category, message) {
  setFailure(category);
  process.stderr.write(`FAILURE_CATEGORY=${category} ${message}\n`);
  process.exit(1);
}

function decision(name, extra = {}) {
  writeOutput({ decision: name, result: "skip", ...extra });
  process.stdout.write(`review repair decision=${name}\n`);
  process.exit(0);
}

function readJson(file, label) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    fail("REPAIR_METADATA_INVALID", `${label} is not valid JSON`);
  }
}

function allowedActor(login) {
  const allowed = String(env.ACTOR_ALLOWLIST || "sironekotoro")
    .split("|")
    .map((item) => item.trim().toLowerCase())
    .filter(Boolean);
  return allowed.includes(String(login ?? "").toLowerCase());
}

if (env.REVIEW_REPAIR_ENABLED !== "true") decision("feature-disabled");

const pr = readJson(env.PR_FILE, "PR payload");
const review = readJson(env.REVIEW_FILE, "review payload");
const comments = readJson(env.COMMENTS_FILE, "PR comments payload");
const target = canonicalRepo(env.TARGET_REPOSITORY);
const dispatcher = canonicalRepo(env.DISPATCHER_REPOSITORY);
const strictReviewer = env.STRICT_REVIEWER === "true";
const executorResume = env.EXECUTOR_RESUME === "true";
const maxAttempts = Number.parseInt(env.REVIEW_REPAIR_MAX || "3", 10);

if (!Number.isInteger(maxAttempts) || maxAttempts < 1 || maxAttempts > 10) {
  fail("REPAIR_METADATA_INVALID", "REVIEW_REPAIR_MAX must be between 1 and 10");
}

if (String(review.state ?? "").toUpperCase() !== "CHANGES_REQUESTED") decision("ignored-state");
if (env.REVIEW_DECISION && String(env.REVIEW_DECISION).toUpperCase() !== "CHANGES_REQUESTED") {
  decision("resolved-review");
}
const reviewer = review.user?.login;
if (!allowedActor(reviewer)) {
  if (strictReviewer) fail("UNAUTHORIZED_ACTOR", "reviewer is not authorized");
  decision("unauthorized-reviewer");
}
if (env.EVENT_ACTOR && String(env.EVENT_ACTOR).toLowerCase() !== String(reviewer).toLowerCase()) {
  fail("UNAUTHORIZED_ACTOR", "event actor does not match submitted review author");
}

if (pr.state !== "open" || pr.merged_at || pr.draft) decision("inactive-pr");
if (pr.user?.type !== "Bot") decision("non-agent-pr");

const marker = String(pr.body ?? "").match(/<!-- agent-dispatch-task:v1:([A-Za-z0-9+/=]+) -->/);
if (!marker) decision("non-agent-pr");

let metadataBytes;
let metadata;
try {
  metadataBytes = Buffer.from(marker[1], "base64");
  metadata = JSON.parse(metadataBytes.toString("utf8"));
} catch {
  fail("REPAIR_METADATA_INVALID", "agent task metadata marker cannot be decoded");
}

if (metadata.schema !== "agent-dispatch-task/v1") fail("REPAIR_METADATA_INVALID", "unsupported task metadata schema");
if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/.test(String(metadata.task_id ?? ""))) {
  fail("REPAIR_METADATA_INVALID", "task_id is not safe for an agent branch");
}
if (!/^issue#[1-9][0-9]*$/.test(String(metadata.source ?? "")) && metadata.source !== "workflow_dispatch") {
  fail("REPAIR_METADATA_INVALID", "task source is not recognized");
}
if (typeof metadata.prompt !== "string" || metadata.prompt.length === 0 || metadata.prompt.length > 50000) {
  fail("REPAIR_METADATA_INVALID", "original task prompt has an invalid size");
}
if (typeof review.body !== "string" || review.body.length > 20000) {
  fail("REPAIR_METADATA_INVALID", "review body exceeds the repair input bound");
}

const expectedBranch = `agent/${metadata.task_id}`;
const baseRepo = canonicalRepo(pr.base?.repo?.full_name);
const headRepo = canonicalRepo(pr.head?.repo?.full_name);
const metadataTarget = canonicalRepo(metadata.target_repository);
const metadataDispatcher = canonicalRepo(metadata.dispatcher_repository);
const writer = String(metadata.writer_login ?? "").toLowerCase();
const prWriter = String(pr.user?.login ?? "").toLowerCase();

if (!target || metadataTarget !== target || baseRepo !== target || headRepo !== target) {
  fail("REPAIR_PR_IDENTITY_MISMATCH", "target/base/head repository identity mismatch");
}
if (!dispatcher || metadataDispatcher !== dispatcher) {
  fail("REPAIR_PR_IDENTITY_MISMATCH", "dispatcher repository identity mismatch");
}
if (!writer || writer !== prWriter) fail("REPAIR_PR_IDENTITY_MISMATCH", "PR author does not match dispatcher principal");
if (pr.head?.ref !== expectedBranch) fail("REPAIR_BRANCH_MISMATCH", "PR head branch does not match immutable task id");
if (!pr.base?.ref || pr.base.ref === pr.head.ref) fail("REPAIR_BRANCH_MISMATCH", "PR base branch is invalid");
if (!pr.head?.sha || review.commit_id !== pr.head.sha) decision("stale-review");

const reviewId = Number(review.id);
const prNumber = Number(pr.number);
if (!Number.isSafeInteger(reviewId) || reviewId < 1 || !Number.isSafeInteger(prNumber) || prNumber < 1) {
  fail("REPAIR_METADATA_INVALID", "PR or review id is invalid");
}

if (env.EXPECTED_PR_NUMBER && Number(env.EXPECTED_PR_NUMBER) !== prNumber) {
  fail("REPAIR_EXECUTOR_REQUEST_INVALID", "executor PR number does not match authoritative PR metadata");
}
if (env.EXPECTED_REVIEW_ID && Number(env.EXPECTED_REVIEW_ID) !== reviewId) {
  fail("REPAIR_EXECUTOR_REQUEST_INVALID", "executor review id does not match authoritative review metadata");
}
if (env.EXPECTED_HEAD_SHA && env.EXPECTED_HEAD_SHA !== pr.head.sha) {
  fail("REPAIR_EXECUTOR_REQUEST_INVALID", "executor reviewed head SHA does not match current PR head");
}

const markerPattern = /<!-- agent-review-repair:v1 status=(started|dispatched|executor-started|completed|failed|limit) review_id=([0-9]+) attempt=([0-9]+) -->/g;
const trustedMarkers = [];
for (const comment of Array.isArray(comments) ? comments : []) {
  if (String(comment.user?.login ?? "").toLowerCase() !== writer) continue;
  for (const match of String(comment.body ?? "").matchAll(markerPattern)) {
    trustedMarkers.push({ status: match[1], reviewId: Number(match[2]), attempt: Number(match[3]) });
  }
}

const startedReviewIds = new Set(trustedMarkers.filter((item) => item.status === "started").map((item) => item.reviewId));
const attemptsUsed = startedReviewIds.size;
let attempt = attemptsUsed + 1;

if (executorResume) {
  const expectedAttempt = Number(env.EXPECTED_ATTEMPT);
  if (!Number.isSafeInteger(expectedAttempt) || expectedAttempt < 1 || expectedAttempt > maxAttempts) {
    fail("REPAIR_EXECUTOR_REQUEST_INVALID", "executor attempt is outside the configured bound");
  }
  const reserved = trustedMarkers.some((item) =>
    item.status === "started" && item.reviewId === reviewId && item.attempt === expectedAttempt
  );
  if (!reserved) fail("REPAIR_EXECUTOR_REQUEST_INVALID", "trusted dispatcher reservation marker is missing");
  if (trustedMarkers.some((item) =>
    item.reviewId === reviewId && ["executor-started", "completed", "failed", "limit"].includes(item.status)
  )) decision("duplicate-review");
  if (attemptsUsed !== expectedAttempt) {
    fail("REPAIR_EXECUTOR_REQUEST_INVALID", "executor attempt does not match trusted PR attempt state");
  }
  attempt = expectedAttempt;
} else if (trustedMarkers.some((item) => item.reviewId === reviewId)) {
  decision("duplicate-review");
}

const metadataSha = crypto.createHash("sha256").update(metadataBytes).digest("hex");
const normalizedTask = {
  ...metadata,
  target_repository: target,
  dispatcher_repository: dispatcher,
  mode: "review_repair",
  metadata_sha256: metadataSha,
  review: {
    id: reviewId,
    reviewer,
    body: review.body,
    submitted_at: review.submitted_at ?? "",
    pr_number: prNumber,
    head_sha: pr.head.sha,
    head_branch: pr.head.ref,
    base_branch: pr.base.ref,
    attempt,
    attempts_used: attemptsUsed,
  },
  request: {
    detected_at: env.DETECTED_AT || "",
    dispatched_at: env.DISPATCHED_AT || "",
    dispatcher_run_id: env.DISPATCHER_RUN_ID || "",
  },
};
fs.writeFileSync(taskFile, JSON.stringify(normalizedTask, null, 2));

const commonOutputs = {
  pr_number: prNumber,
  review_id: reviewId,
  head_branch: pr.head.ref,
  head_sha: pr.head.sha,
  base_branch: pr.base.ref,
  attempt,
  source: metadata.source,
};

if (!executorResume && attemptsUsed >= maxAttempts) {
  setFailure("REPAIR_LIMIT_REACHED");
  decision("limit-reached", commonOutputs);
}

writeOutput({ decision: "run", result: "pass", ...commonOutputs });
process.stdout.write(`review repair decision=run pr=${prNumber} review=${reviewId} attempt=${attempt}\n`);
