'use strict';

// Discovery projects current declarations, never executable adapters or saved
// invocation receipts. It does not limit the catalog or infer a tree from IDs.
function discoveryRows(descriptors, savedCommands, { availability = () => undefined, locations = {} } = {}) {
  if (!Array.isArray(descriptors) || !Array.isArray(savedCommands) || typeof availability !== 'function'
    || !locations || typeof locations !== 'object' || Array.isArray(locations)) {
    throw new Error('Discovery requires current command arrays, availability and explicit locations');
  }
  const seen = new Set();
  const locationFor = id => locations instanceof Map ? locations.get(id)
    : Object.getOwnPropertyDescriptor(locations, id)?.value;
  const rows = [];
  function add(command, saved) {
    if (!command || typeof command !== 'object' || Array.isArray(command)
      || typeof command.id !== 'string' || !command.id
      || typeof command.name !== 'string' || !command.name.trim()) {
      throw new Error('Discovery requires commands with stable IDs and display names');
    }
    if (seen.has(command.id)) throw new Error('Duplicate discovery command ID: ' + command.id);
    seen.add(command.id);
    const label = command.name.trim(), location = locationFor(command.id);
    if (location !== undefined && (typeof location !== 'string' || !location.trim())) {
      throw new Error('Discovery locations must be explicit nonempty labels');
    }
    const checked = availability(command.id, command);
    if (checked !== undefined && checked !== null && typeof checked !== 'string') {
      throw new Error('Discovery availability must return a reason or no reason');
    }
    const reason = typeof checked === 'string' ? checked.trim() : '';
    const description = location === undefined ? saved ? 'User command' : undefined : location.trim();
    const detail = typeof command.description === 'string' ? command.description.trim() : '';
    const optionalPresentation = {}, row = { id: command.id, label };
    if (description && description !== label) {
      row.description = description; optionalPresentation.status = true;
    }
    if (reason) {
      // Availability changes the user's decision. Unlike optional descriptive
      // text, its reason must remain visible in Compact and Minimal as well.
      row.detail = reason; row.unavailable = reason; row.inspectOnly = true;
    } else if (detail && detail !== label && detail !== description && detail !== command.id) {
      row.detail = detail; optionalPresentation.details = true;
    }
    if (Object.keys(optionalPresentation).length) row.optionalPresentation = optionalPresentation;
    rows.push(row);
  }
  // Preserve the caller's explicit order, including its order for user commands.
  // Searching hidden aliases/IDs needs a separate query model; these display
  // rows deliberately do not add those values as visual noise.
  for (const command of descriptors) add(command, false);
  for (const command of savedCommands) add(command, true);
  const labels = new Map();
  for (const row of rows) {
    if (!labels.has(row.label)) labels.set(row.label, []);
    labels.get(row.label).push(row);
  }
  for (const group of labels.values()) {
    if (group.length < 2) continue;
    const contexts = new Map();
    for (const row of group) if (row.description) contexts.set(row.description, (contexts.get(row.description) || 0) + 1);
    for (const row of group) {
      // Matching display names need a visible distinction in every density.
      // Prefer a distinct declared context; use the stable ID only when that
      // context is absent or still ambiguous. IDs always remain owned row data.
      if (!row.description || contexts.get(row.description) !== 1) {
        row.description = row.description ? row.description + ' · ' + row.id : row.id;
      }
      if (row.optionalPresentation) {
        delete row.optionalPresentation.status;
        if (!Object.keys(row.optionalPresentation).length) delete row.optionalPresentation;
      }
    }
  }
  return rows;
}

module.exports = { discoveryRows };
