'use strict';

// Session navigation is scalar data. No widget, command callback, receipt,
// editor, or original item identity survives a closed native form.
const MAX_VIEWS = 64, MAX_TEXT_BYTES = 4096;
const routes = new Set(['discovery', 'user.commands_manage', 'input.rules_manage']);
function scalar(value, limit = 1024) {
  return typeof value === 'string' && value.length > 0 && Buffer.byteLength(value, 'utf8') <= limit
    && !/[\u0000-\u001f\u007f\ud800-\udfff]/u.test(value.replace(/[\ud800-\udbff][\udc00-\udfff]/g, '')) ? value : undefined;
}
function data(object, name) {
  if (!object || typeof object !== 'object') return undefined;
  const property = Object.getOwnPropertyDescriptor(object, name);
  return property && Object.prototype.hasOwnProperty.call(property, 'value') ? property.value : undefined;
}
function identity(item) {
  const command = data(item, 'command'), input = data(item, 'input');
  const candidates = [
    ['id', data(item, 'id')], ['command', typeof command === 'string' ? command : data(command, 'id')],
    ['input', data(input, 'name')], ['action', data(item, 'action')],
    ['key', data(item, 'key')], ['mode', data(item, 'mode')]
  ];
  for (const [kind, value] of candidates) if (scalar(value)) return kind + ':' + value;
  const value = data(item, 'value');
  if (typeof value === 'boolean' || typeof value === 'number' && Number.isFinite(value)) return 'value:' + typeof value + ':' + value;
  if (scalar(value)) return 'value:string:' + value;
  const label = scalar(data(item, 'label'));
  return label === undefined ? undefined : 'label:' + label;
}
function text(value) {
  // Oversized/invalid text replaces the old entry with no text rather than
  // reviving an obsolete query or silently truncating an input draft.
  return typeof value === 'string' && Buffer.byteLength(value, 'utf8') <= MAX_TEXT_BYTES
    && !/[\ud800-\udfff]/u.test(value.replace(/[\ud800-\udbff][\udc00-\udfff]/g, '')) ? value : undefined;
}
class NavigationMemory {
  constructor() { this.views = new Map(); this.generation = 0; this.serial = 0; this.route = 'discovery'; }
  setRoute(route) {
    if (!routes.has(route)) throw new Error('Navigation route is not a resumable authoring view');
    this.route = route;
  }
  getRoute() { return this.route; }
  clear(prefix) {
    if (prefix !== undefined && !scalar(prefix, 256)) throw new Error('Navigation prefix is invalid');
    ++this.generation;
    if (prefix === undefined) { this.views.clear(); this.route = 'discovery'; }
    else for (const key of this.views.keys()) if (key.startsWith(prefix)) this.views.delete(key);
  }
  open(key, kind, items, options = {}) {
    if (!scalar(key, 256) || !['pick', 'input'].includes(kind)) throw new Error('Navigation memory needs a bounded key and native form kind');
    if (kind === 'pick' && !Array.isArray(items)) throw new Error('Navigation memory needs current pick items');
    const restored = { ...options };
    // These forms have no resumable navigation. In particular a password must
    // not inherit an earlier value even if a caller accidentally reuses a key.
    if (options.password || options.canPickMany) { this.views.delete(key); return { options: restored, checkpoint() { return false; } }; }
    let rows = kind === 'pick' ? items.slice() : null;
    let identities = rows && rows.map(identity);
    const uniqueIndex = id => identities && identities.filter(value => value === id).length === 1 ? identities.indexOf(id) : -1;
    const previous = this.views.get(key), ticket = ++this.serial, generation = this.generation;
    if (previous && previous.kind === kind) {
      if (previous.value !== undefined) restored.value = previous.value;
      if (kind === 'pick' && previous.active !== undefined) {
        const index = uniqueIndex(previous.active);
        if (index >= 0) restored.activeItem = rows[index];
      }
    }
    const slot = { kind, ticket, ...(previous && previous.kind === kind ? previous : {}) };
    slot.ticket = ticket;
    this.views.delete(key); this.views.set(key, slot);
    while (this.views.size > MAX_VIEWS) this.views.delete(this.views.keys().next().value);
    let done = false;
    const checkpoint = snapshot => {
      if (done) return false;
      done = true;
      try {
        if (generation !== this.generation || this.views.get(key) !== slot || slot.ticket !== ticket) return false;
        if (!snapshot || typeof snapshot.accepted !== 'boolean') return false;
        if (kind === 'input' && snapshot.accepted) { this.views.delete(key); return true; }
        const value = text(snapshot.value);
        let active;
        if (kind === 'pick' && Array.isArray(snapshot.activeItems) && snapshot.activeItems.length === 1) {
          const index = rows.indexOf(snapshot.activeItems[0]);
          if (index >= 0 && identities[index] !== undefined && uniqueIndex(identities[index]) === index) active = identities[index];
        }
        // Only scalar fields enter the cache; no closure or row is retained.
        const saved = { kind, ticket, ...(value === undefined ? {} : { value }), ...(active === undefined ? {} : { active }) };
        this.views.delete(key); this.views.set(key, saved); return true;
      } finally { rows = null; identities = null; }
    };
    return { options: restored, checkpoint };
  }
}
module.exports = { NavigationMemory, MAX_VIEWS, MAX_TEXT_BYTES };
