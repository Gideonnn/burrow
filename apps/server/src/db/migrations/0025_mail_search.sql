CREATE TABLE `mail_contacts` (
	`mailbox_id` text NOT NULL,
	`email` text NOT NULL,
	`name` text,
	`sent` integer DEFAULT 0 NOT NULL,
	`received` integer DEFAULT 0 NOT NULL,
	`last_at` integer NOT NULL,
	FOREIGN KEY (`mailbox_id`) REFERENCES `mailboxes`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `mail_contacts_mailbox_email` ON `mail_contacts` (`mailbox_id`,`email`);--> statement-breakpoint
CREATE TABLE `message_search_keys` (
	`id` integer PRIMARY KEY NOT NULL,
	`message_id` text NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `message_search_keys_message_id_unique` ON `message_search_keys` (`message_id`);--> statement-breakpoint
CREATE TABLE `message_vectors` (
	`message_id` text PRIMARY KEY NOT NULL,
	`model` text NOT NULL,
	`vector` blob NOT NULL,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	FOREIGN KEY (`message_id`) REFERENCES `messages`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `message_vectors_model` ON `message_vectors` (`model`);--> statement-breakpoint
CREATE VIEW `message_search_source` AS
SELECT
  m.id AS message_id,
  m.subject AS subject,
  trim(
    coalesce(m."from"->>'name', '') || ' ' || coalesce(m."from"->>'email', '') || ' ' ||
    coalesce((SELECT group_concat(coalesce(j.value->>'name', '') || ' ' || coalesce(j.value->>'email', ''), ' ') FROM json_each(m."to") j), '') || ' ' ||
    coalesce((SELECT group_concat(coalesce(j.value->>'name', '') || ' ' || coalesce(j.value->>'email', ''), ' ') FROM json_each(m.cc) j), '')
  ) AS people,
  substr(coalesce(m.body_text, ''), 1, 20000) AS body,
  trim(
    coalesce(f.summary, '') || ' ' ||
    coalesce((SELECT group_concat(value, ' ') FROM json_each(f.keywords)), '') || ' ' ||
    coalesce((SELECT group_concat(value, ' ') FROM json_each(f.people)), '') || ' ' ||
    coalesce((SELECT group_concat(value, ' ') FROM json_each(f.organisations)), '') || ' ' ||
    coalesce((SELECT group_concat(o.search_text, ' ') FROM outing_messages om JOIN outings o ON o.id = om.outing_id WHERE om.message_id = m.id), '')
  ) AS facts
FROM messages m LEFT JOIN message_facts f ON f.message_id = m.id;
--> statement-breakpoint
CREATE VIRTUAL TABLE `message_search` USING fts5(subject, people, body, facts, content='', contentless_delete=1, tokenize='unicode61 remove_diacritics 2');
--> statement-breakpoint
INSERT INTO `message_search_keys` (message_id) SELECT id FROM messages ORDER BY received_at;
--> statement-breakpoint
INSERT INTO `message_search` (rowid, subject, people, body, facts)
SELECT k.id, s.subject, s.people, s.body, s.facts
FROM message_search_source s JOIN message_search_keys k ON k.message_id = s.message_id;
--> statement-breakpoint
CREATE TRIGGER `message_search_insert` AFTER INSERT ON `messages` BEGIN
  INSERT INTO message_search_keys (message_id) VALUES (new.id);
  INSERT INTO message_search (rowid, subject, people, body, facts)
  SELECT k.id, s.subject, s.people, s.body, s.facts
  FROM message_search_source s JOIN message_search_keys k ON k.message_id = s.message_id
  WHERE s.message_id = new.id;
END;
--> statement-breakpoint
CREATE TRIGGER `message_search_update` AFTER UPDATE OF subject, "from", "to", cc, body_text ON `messages` BEGIN
  DELETE FROM message_search WHERE rowid = (SELECT id FROM message_search_keys WHERE message_id = new.id);
  INSERT INTO message_search (rowid, subject, people, body, facts)
  SELECT k.id, s.subject, s.people, s.body, s.facts
  FROM message_search_source s JOIN message_search_keys k ON k.message_id = s.message_id
  WHERE s.message_id = new.id;
END;
--> statement-breakpoint
CREATE TRIGGER `message_search_delete` AFTER DELETE ON `messages` BEGIN
  DELETE FROM message_search WHERE rowid = (SELECT id FROM message_search_keys WHERE message_id = old.id);
  DELETE FROM message_search_keys WHERE message_id = old.id;
END;
--> statement-breakpoint
CREATE TRIGGER `message_search_facts_insert` AFTER INSERT ON `message_facts` BEGIN
  DELETE FROM message_search WHERE rowid = (SELECT id FROM message_search_keys WHERE message_id = new.message_id);
  INSERT INTO message_search (rowid, subject, people, body, facts)
  SELECT k.id, s.subject, s.people, s.body, s.facts
  FROM message_search_source s JOIN message_search_keys k ON k.message_id = s.message_id
  WHERE s.message_id = new.message_id;
END;
--> statement-breakpoint
CREATE TRIGGER `message_search_facts_update` AFTER UPDATE OF summary, keywords, people, organisations ON `message_facts` BEGIN
  DELETE FROM message_search WHERE rowid = (SELECT id FROM message_search_keys WHERE message_id = new.message_id);
  INSERT INTO message_search (rowid, subject, people, body, facts)
  SELECT k.id, s.subject, s.people, s.body, s.facts
  FROM message_search_source s JOIN message_search_keys k ON k.message_id = s.message_id
  WHERE s.message_id = new.message_id;
END;
--> statement-breakpoint
INSERT INTO `mail_contacts` (mailbox_id, email, name, sent, received, last_at)
SELECT mailbox_id, email, max(name), sum(sent), sum(received), max(at) FROM (
  SELECT m.mailbox_id, lower(m."from"->>'email') AS email, nullif(m."from"->>'name', '') AS name, 0 AS sent, 1 AS received, m.received_at AS at
  FROM messages m WHERE m.folder NOT IN ('sent', 'spam', 'trash')
  UNION ALL
  SELECT m.mailbox_id, lower(j.value->>'email'), nullif(j.value->>'name', ''), 1, 0, m.received_at
  FROM messages m, json_each(m."to") j WHERE m.folder = 'sent'
  UNION ALL
  SELECT m.mailbox_id, lower(j.value->>'email'), nullif(j.value->>'name', ''), 1, 0, m.received_at
  FROM messages m, json_each(m.cc) j WHERE m.folder = 'sent'
) c
WHERE email IS NOT NULL AND email != (SELECT lower(address) FROM mailboxes b WHERE b.id = c.mailbox_id)
GROUP BY mailbox_id, email;
--> statement-breakpoint
CREATE TRIGGER `mail_contacts_received` AFTER INSERT ON `messages`
WHEN new.folder NOT IN ('sent', 'spam', 'trash') AND new."from"->>'email' IS NOT NULL BEGIN
  INSERT INTO mail_contacts (mailbox_id, email, name, sent, received, last_at)
  SELECT new.mailbox_id, lower(new."from"->>'email'), nullif(new."from"->>'name', ''), 0, 1, new.received_at
  WHERE lower(new."from"->>'email') != (SELECT lower(address) FROM mailboxes WHERE id = new.mailbox_id)
  ON CONFLICT (mailbox_id, email) DO UPDATE SET
    received = received + 1,
    name = coalesce(excluded.name, name),
    last_at = max(last_at, excluded.last_at);
END;
--> statement-breakpoint
CREATE TRIGGER `mail_contacts_sent` AFTER INSERT ON `messages`
WHEN new.folder = 'sent' BEGIN
  INSERT INTO mail_contacts (mailbox_id, email, name, sent, received, last_at)
  SELECT new.mailbox_id, lower(j.value->>'email'), nullif(j.value->>'name', ''), 1, 0, new.received_at
  FROM (SELECT value FROM json_each(new."to") UNION ALL SELECT value FROM json_each(new.cc)) j
  WHERE j.value->>'email' IS NOT NULL
    AND lower(j.value->>'email') != (SELECT lower(address) FROM mailboxes WHERE id = new.mailbox_id)
  ON CONFLICT (mailbox_id, email) DO UPDATE SET
    sent = sent + 1,
    name = coalesce(excluded.name, name),
    last_at = max(last_at, excluded.last_at);
END;
--> statement-breakpoint
CREATE TRIGGER `message_search_outing_insert` AFTER INSERT ON `outing_messages` BEGIN
  DELETE FROM message_search WHERE rowid = (SELECT id FROM message_search_keys WHERE message_id = new.message_id);
  INSERT INTO message_search (rowid, subject, people, body, facts)
  SELECT k.id, s.subject, s.people, s.body, s.facts
  FROM message_search_source s JOIN message_search_keys k ON k.message_id = s.message_id
  WHERE s.message_id = new.message_id;
END;
--> statement-breakpoint
CREATE TRIGGER `message_search_outing_delete` AFTER DELETE ON `outing_messages` BEGIN
  DELETE FROM message_search WHERE rowid = (SELECT id FROM message_search_keys WHERE message_id = old.message_id);
  INSERT INTO message_search (rowid, subject, people, body, facts)
  SELECT k.id, s.subject, s.people, s.body, s.facts
  FROM message_search_source s JOIN message_search_keys k ON k.message_id = s.message_id
  WHERE s.message_id = old.message_id;
END;
--> statement-breakpoint
CREATE TRIGGER `message_search_outing_names` AFTER UPDATE OF search_text ON `outings` BEGIN
  DELETE FROM message_search WHERE rowid IN (
    SELECT k.id FROM message_search_keys k JOIN outing_messages om ON om.message_id = k.message_id WHERE om.outing_id = new.id
  );
  INSERT INTO message_search (rowid, subject, people, body, facts)
  SELECT k.id, s.subject, s.people, s.body, s.facts
  FROM message_search_source s JOIN message_search_keys k ON k.message_id = s.message_id
  WHERE s.message_id IN (SELECT message_id FROM outing_messages WHERE outing_id = new.id);
END;
