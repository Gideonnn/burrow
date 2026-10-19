// Operator commands that run on the server machine itself, before any admin
// key exists:
//
//   pnpm --filter @burrow/server cli init <name>        first person + admin key
//   pnpm --filter @burrow/server cli add-person <name>
//   pnpm --filter @burrow/server cli list
//   pnpm --filter @burrow/server cli generate-secret    value for BURROW_SECRET_KEY
//   pnpm --filter @burrow/server cli seed-demo          invented household for development
//   pnpm --filter @burrow/server cli backup <file>        consistent copy of the database
import {
  createKey,
  createPerson,
  listKeys,
  listPeople,
} from './access/service';
import { loadConfig } from './config';
import { SecretBox } from './crypto/secretBox';
import { openDb } from './db/client';
import { routines } from './db/schema';
import { Accounts } from './mail/accounts';

const [command, ...args] = process.argv.slice(2);
const db = () => openDb(loadConfig().dbPath);

switch (command) {
  case 'init': {
    const store = db();
    if (listPeople(store).length > 0) {
      fail(
        'already initialised; create more keys through the API with an admin key',
      );
    }
    const person = createPerson(store, required(args[0], 'name'));
    const { token } = createKey(store, {
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
    const person = createPerson(db(), required(args[0], 'name'));
    console.log(`Created ${person.name} (${person.id}).`);
    break;
  }
  case 'list': {
    const store = db();
    for (const p of listPeople(store)) console.log(`person ${p.id}  ${p.name}`);
    for (const k of listKeys(store)) {
      console.log(
        `key    ${k.id}  ${k.prefix}…  ${k.name}  [${k.rights.join(', ')}]${k.revokedAt ? '  revoked' : ''}`,
      );
    }
    break;
  }
  case 'seed-demo': {
    // An invented household with demo mailboxes, for developing the clients.
    const config = loadConfig();
    if (!config.secretKey)
      fail('set BURROW_SECRET_KEY first (cli generate-secret)');
    const store = db();
    if (listPeople(store).length > 0)
      fail('the database is not empty; use a fresh BURROW_DATA_DIR');
    const accounts = new Accounts({
      db: store,
      box: new SecretBox(config.secretKey),
      publicUrl: config.publicUrl,
      apps: {},
    });
    const gideon = createPerson(store, 'Gideon');
    const eva = createPerson(store, 'Eva');
    for (const [owner, provider, address, seed] of [
      [gideon, 'microsoft', 'gideon@werk.example', 'work'],
      [gideon, 'gmail', 'gideon@example.com', 'personal'],
      [gideon, 'fastmail', 'gideon@fastmail.example', 'invoices'],
      [eva, 'gmail', 'eva@example.com', 'partner'],
    ] as const) {
      accounts.upsertMailbox({
        ownerId: owner.id,
        provider,
        address,
        credentials: { kind: 'demo', seed },
      });
    }
    // A routine that runs on the owner's Mac, to show tasks and runners.
    store
      .insert(routines)
      .values({
        personId: gideon.id,
        name: 'Facturen uitlezen',
        trigger: { kind: 'message', subject: 'factuur' },
        skill: 'key-facts',
        bot: 'kreacher',
        where: 'client',
        fallbackAfterHours: 24,
        approval: true,
        enabled: true,
      })
      .run();
    const all = [
      'read',
      'organize',
      'draft',
      'send',
      'tasks',
      'admin',
    ] as const;
    const keys = [
      [
        'MacBook Gideon',
        createKey(store, {
          personId: gideon.id,
          name: 'MacBook Gideon',
          rights: [...all],
          mailboxIds: null,
        }),
      ],
      [
        'Mac Eva',
        createKey(store, {
          personId: eva.id,
          name: 'Mac Eva',
          rights: ['read', 'organize', 'draft', 'send', 'tasks'],
          mailboxIds: null,
        }),
      ],
    ] as const;
    console.log('Demo household created. Keys, shown once:\n');
    for (const [name, { token }] of keys)
      console.log(`  ${name.padEnd(16)} ${token}`);
    break;
  }
  case 'backup': {
    // A consistent copy of the live database, safe while the server runs.
    const target = required(args[0], 'target file');
    await db().$client.backup(target);
    console.log(`backed up to ${target}`);
    break;
  }
  case 'generate-secret':
    console.log(SecretBox.generateKey());
    break;
  default:
    fail(
      'usage: cli init <name> | add-person <name> | list | generate-secret | seed-demo',
    );
}

function required(value: string | undefined, what: string): string {
  if (!value) fail(`missing ${what}`);
  return value;
}

function fail(message: string): never {
  console.error(message);
  process.exit(1);
}
