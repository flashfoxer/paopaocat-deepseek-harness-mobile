// 提取探针所需的枚举与联合类型（第一轮只看结构）。
import { readFileSync } from 'node:fs';

const schemaPath =
  'D:/Programs/PaopaocatDSH/app/node_modules/@agentclientprotocol/sdk/schema/schema.json';
const defs = JSON.parse(readFileSync(schemaPath, 'utf8')).$defs;

function refName(x) {
  return x && x.$ref ? x.$ref.split('/').pop() : x && x.const !== undefined ? JSON.stringify(x.const) : x && x.type ? JSON.stringify(x.type) : '?';
}

function summarize(name) {
  const d = defs[name];
  if (!d) {
    console.log('\n=== ' + name + ' : NOT FOUND ===');
    return;
  }
  const parts = [];
  if (d.type !== undefined) parts.push('type = ' + JSON.stringify(d.type));
  if (d.enum !== undefined) parts.push('enum = ' + JSON.stringify(d.enum));
  if (d.const !== undefined) parts.push('const = ' + JSON.stringify(d.const));
  if (d.oneOf) parts.push('oneOf = ' + JSON.stringify(d.oneOf.map(refName)));
  if (d.anyOf) parts.push('anyOf = ' + JSON.stringify(d.anyOf.map(refName)));
  if (d.allOf) parts.push('allOf = ' + JSON.stringify(d.allOf.map(refName)));
  if (d.required) parts.push('required = ' + JSON.stringify(d.required));
  if (d.properties) parts.push('props = ' + JSON.stringify(Object.keys(d.properties)));
  console.log('\n=== ' + name + ' ===');
  console.log(parts.join('\n'));
  if (['ProtocolVersion', 'RequestPermissionOutcome', 'SelectedPermissionOutcome', 'PermissionOptionKind', 'StopReason'].includes(name)) {
    console.log('RAW: ' + JSON.stringify(d).slice(0, 1000));
  }
}

const want = [
  'ProtocolVersion',
  'RequestPermissionOutcome',
  'SelectedPermissionOutcome',
  'PermissionOptionKind',
  'StopReason',
  'AgentCapabilities',
  'SessionCapabilities',
  'SessionUpdate',
  'ToolCallUpdate',
  'ToolCall',
  'ContentBlock',
  'SessionConfigOption',
];

for (const k of want) summarize(k);
