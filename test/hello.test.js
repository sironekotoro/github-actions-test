const test = require('node:test');
const assert = require('node:assert/strict');

const { message } = require('../hello');

test('message returns the Codex greeting', () => {
  assert.equal(message(), 'Hello from Codex');
});
