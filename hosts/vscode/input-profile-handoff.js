'use strict';
// Changing acquisition engines cannot erase an uncertain effect owned by the
// previous controller. Keep that controller available for inspection on refusal.
function refused(message, cause) {
  return Object.assign(new Error('Input profile handoff refused: ' + message + '. Inspect the current editor outcome before changing profiles.'),
    { code: 'RE35_INPUT_HANDOFF_UNCERTAIN', effects: 'inspect-outcome', ...(cause ? { cause } : {}) });
}
function inspect(connection, retired = false) {
  const state = connection.getState();
  if (!state || typeof state !== 'object') throw refused('the previous input state could not be inspected');
  if (state.blocked || state.busy || state.queued > 0) throw refused(state.message || 'the previous input effect is still pending or unconfirmed');
  if (retired && state.enabled) throw refused('the previous input controller still owns editor keys');
  return state;
}
async function retireInputConnection(connection) {
  if (!connection || typeof connection.suspend !== 'function' || typeof connection.getState !== 'function'
    || typeof connection.dispose !== 'function') throw new Error('Input profile handoff requires an owned input controller');
  try { await connection.suspend('Input profile changed'); }
  catch (cause) { throw refused(cause.message || 'the previous input could not be drained', cause); }
  // This check must precede disposal: a blocked controller holds the evidence
  // that explains why a new engine cannot be activated safely.
  inspect(connection);
  try { await connection.dispose(); }
  catch (cause) { throw refused(cause.message || 'the previous input controller could not be retired', cause); }
  return inspect(connection, true);
}
module.exports = { retireInputConnection };
