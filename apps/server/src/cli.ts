// Operator commands that run on the server machine itself, before any admin
// key exists:
//
//   pnpm --filter @burrow/server cli init <name>        first person + admin key
//   pnpm --filter @burrow/server cli add-person <name>
//   pnpm --filter @burrow/server cli list
import {
  createKey,
  createPerson,
  listKeys,
  listPeople,
} from './access/service';
import { loadConfig } from './config';
import { openDb } from './db/client';

const [command, ...args] = process.argv.slice(2);
const db = openDb(loadConfig().dbPath);

switch (command) {
  case 'init': {
    if (listPeople(db).length > 0) {
      fail(
        'already initialised; create more keys through the API with an admin key',
      );
    }
    const person = createPerson(db, required(args[0], 'name'));
    const { token } = createKey(db, {
      personId: person.id,
      name: 'Admin (created by init)',
      rights: ['read', 'organize', 'draft', 'send', 'tasks', 'admin'],
      mailboxIds: null,
    });
    console.log(`Created ${person.name} (${person.id}).`);
    console.log(`Admin key, shown once:\n\n  ${token}\n`);
    break;
  }
  case 'add-person': {
    const person = createPerson(db, required(args[0], 'name'));
    console.log(`Created ${person.name} (${person.id}).`);
    break;
  }
  case 'list': {
    for (const p of listPeople(db)) console.log(`person ${p.id}  ${p.name}`);
    for (const k of listKeys(db)) {
      console.log(
        `key    ${k.id}  ${k.prefix}…  ${k.name}  [${k.rights.join(', ')}]${k.revokedAt ? '  revoked' : ''}`,
      );
    }
    break;
  }
  default:
    fail('usage: cli init <name> | add-person <name> | list');
}

function required(value: string | undefined, what: string): string {
  if (!value) fail(`missing ${what}`);
  return value;
}

function fail(message: string): never {
  console.error(message);
  process.exit(1);
}
