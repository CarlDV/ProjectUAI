// One-shot game simulator for testing the bridge web UI.
// Speaks the real game-half protocol: POSTs a snapshot + state, then events.
const TOKEN = process.argv[2];
const BASE = process.argv[3] || 'http://127.0.0.1:8790';

function post(path, body) {
  return fetch(BASE + path, {
    method: 'POST',
    headers: { 'content-type': 'application/json', Authorization: 'Bearer ' + TOKEN },
    body: JSON.stringify(body),
  });
}

const snapshot = [
  { kind: 'user', text: 'inspect the workspace' },
  {
    kind: 'tool:call', id: 'call-1', name: 'instance_tree', group: 'instance', risk: 'read',
    arguments: { root: 'Workspace', depth: 2 },
  },
  { kind: 'tool:result', id: 'call-1', name: 'instance_tree', text: 'Workspace\n  Camera\n  Terrain\n  Map (Model)\n  SpawnLocation' },
  { kind: 'assistant:text', text: 'Workspace has **4** children:\n- Camera\n- Terrain\n- Map (Model)\n- SpawnLocation\n\n`instance_tree` with depth 2 shows no players present.' },
];

const state = {
  place: { id: 275, name: 'Arsenal' },
  caps: { executor: 'Synapse Z', http: 'executor', summary: 'Synapse Z | transport executor | ua yes | fs yes | exec yes' },
  agent: { status: 'Ready', busy: false, provider: 'OpenRouter', model: 'anthropic/claude-sonnet-4.5' },
  usage: { prompt: 12345, completion: 2100, total: 14445, cost: 0.0817, requests: 7, estimated: false },
  permissions: { mode: 'ask', pending: 0 },
  threads: [
    { id: 't1', title: 'inspect the workspace', place: 'Arsenal', busy: false, turns: 3, updatedAt: 1, active: true },
    { id: 't2', title: 'find hidden remotes', place: 'Arsenal', busy: false, turns: 8, updatedAt: 0, active: false },
  ],
  providers: [
    {
      id: 'openrouter', label: 'OpenRouter', model: 'anthropic/claude-sonnet-4.5',
      models: ['anthropic/claude-sonnet-4.5', 'anthropic/claude-haiku-4.5', 'google/gemini-2.5-pro', 'openai/gpt-4o'],
      enabled: true, health: { ok: 12, fail: 1, lastError: '' }, cooling: false,
    },
    {
      id: 'local', label: 'LM Studio', model: 'qwen2.5-32b',
      models: ['qwen2.5-32b', 'llama-3.3-70b'],
      enabled: true, health: { ok: 0, fail: 3, lastError: 'connection refused' }, cooling: true,
    },
  ],
  activeProvider: 'openrouter',
  tools: [
    { name: 'instance_find', group: 'instance', description: 'Find instances by class name or name pattern.', risk: 'read' },
    { name: 'instance_tree', group: 'instance', description: 'Generate a hierarchy tree of the DataModel.', risk: 'read' },
    { name: 'instance_set', group: 'instance', description: 'Set property values on an instance.', risk: 'write' },
    { name: 'player_list', group: 'players', description: 'List players with teams and leaderstats.', risk: 'read' },
    { name: 'player_teleport', group: 'players', description: 'Teleport to a player.', risk: 'write' },
    { name: 'remote_spy', group: 'remotes', description: 'Log outbound remote traffic.', risk: 'read' },
    { name: 'perf_fps', group: 'perf', description: 'Measure framerate and hitch frequency.', risk: 'read' },
    { name: 'dispatch_agent', group: 'agentself', description: 'Dispatch a nested subagent with a task.', risk: 'write' },
  ],
  subagents: [
    { id: 'agent-x1', label: 'survey hidden items', task: 'Survey the environment for hidden items.', preset: 'read', status: 'running', ms: null, messages: 3, report: null },
    { id: 'agent-x0', label: 'count spawn points', task: 'Count all SpawnLocations.', preset: 'read', status: 'done', ms: 8400, messages: 6, report: 'Found 12 SpawnLocations across 3 maps.' },
  ],
};

async function main() {
  let res = await post('/api/agent/events', { snapshot, state });
  console.log('snapshot+state:', res.status);

  await new Promise(r => setTimeout(r, 600));

  // A live turn: request telemetry, tool call, result, reply, usage.
  const events = [
    { kind: 'request:start', provider: 'OpenRouter', model: 'anthropic/claude-sonnet-4.5', attempt: 1, messages: 8, stream: true },
    { kind: 'assistant:reasoning', text: 'The user wants performance stats. I should call perf_fps to measure the current framerate before reporting.' },
    { kind: 'tool:call', id: 'call-2', name: 'perf_fps', group: 'perf', risk: 'read', arguments: { sampleSeconds: 1 } },
    { kind: 'request:done', provider: 'OpenRouter', model: 'anthropic/claude-sonnet-4.5', ms: 1240, streamed: true },
    { kind: 'tool:result', id: 'call-2', name: 'perf_fps', text: 'FPS: 59.8\nMemory: 412 MB\nPing: 28 ms' },
    { kind: 'assistant:text', text: 'Performance is healthy:\n- **FPS**: 59.8\n- **Memory**: 412 MB\n- **Ping**: 28 ms' },
    { kind: 'usage', session: { prompt: 13500, completion: 2450, total: 15950, cost: 0.091 }, turn: { prompt: 1155, completion: 350, total: 1505, cost: 0.0093 } },
    { kind: 'subagent:done', id: 'agent-x1', ms: 21300, ok: true, messages: 9, text: 'Found 3 hidden items: a coin under the stairs, a badge behind the waterfall, and a locked chest in the cave.' },
    { kind: 'turn:end', text: '' },
  ];
  res = await post('/api/agent/events', { events });
  console.log('events:', res.status);

  // Updated state after the turn.
  const state2 = JSON.parse(JSON.stringify(state));
  state2.usage = { prompt: 13500, completion: 2450, total: 15950, cost: 0.091, requests: 8, estimated: false };
  state2.subagents[0] = { id: 'agent-x1', label: 'survey hidden items', task: 'Survey the environment for hidden items.', preset: 'read', status: 'done', ms: 21300, messages: 9, report: 'Found 3 hidden items: a coin under the stairs, a badge behind the waterfall, and a locked chest in the cave.' };
  res = await post('/api/agent/events', { events: [], state: state2 });
  console.log('state2:', res.status);
}

main().catch((err) => { console.error(err); process.exit(1); });
