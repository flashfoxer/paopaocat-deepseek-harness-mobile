// 从 ACP 官方 JSON Schema 提取探针需要的确切结构，避免手写协议时猜字段。
import { readFileSync } from 'node:fs';

const schemaPath =
  'D:/Programs/PaopaocatDSH/app/node_modules/@agentclientprotocol/sdk/schema/schema.json';

const s = JSON.parse(readFileSync(schemaPath, 'utf8'));
console.log('top keys:', Object.keys(s).join(', '));

const defs = s.$defs || s.definitions || {};
const keys = Object.keys(defs);
console.log('def count:', keys.length);
console.log('def names:', keys.join(', '));

const want = [
  'InitializeRequest',
  'InitializeResponse',
  'NewSessionRequest',
  'NewSessionResponse',
  'PromptRequest',
  'PromptResponse',
  'RequestPermissionRequest',
  'RequestPermissionResponse',
  'PermissionOption',
  'SessionNotification',
];

for (const k of want) {
  console.log('\n=== ' + k + ' ===');
  if (defs[k]) {
    console.log(JSON.stringify(defs[k], null, 1).slice(0, 1800));
  } else {
    console.log('NOT FOUND');
  }
}
