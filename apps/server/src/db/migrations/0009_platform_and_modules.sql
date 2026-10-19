CREATE TABLE `shares` (
	`id` text PRIMARY KEY NOT NULL,
	`module` text NOT NULL,
	`item_id` text NOT NULL,
	`person_id` text NOT NULL,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	FOREIGN KEY (`person_id`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `shares_item_person` ON `shares` (`module`,`item_id`,`person_id`);--> statement-breakpoint
CREATE TABLE `uploads` (
	`id` text PRIMARY KEY NOT NULL,
	`person_id` text NOT NULL,
	`size` integer NOT NULL,
	`received` integer DEFAULT 0 NOT NULL,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	FOREIGN KEY (`person_id`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
PRAGMA foreign_keys=OFF;--> statement-breakpoint
CREATE TABLE `__new_tasks` (
	`id` text PRIMARY KEY NOT NULL,
	`kind` text DEFAULT 'routine' NOT NULL,
	`routine_id` text,
	`person_id` text NOT NULL,
	`subject_type` text,
	`subject_id` text,
	`input` text,
	`status` text NOT NULL,
	`where` text DEFAULT 'server' NOT NULL,
	`fallback_at` integer,
	`result` text,
	`error` text,
	`attempts` integer DEFAULT 0 NOT NULL,
	`claimed_by` text,
	`claimed_at` integer,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	`updated_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	FOREIGN KEY (`routine_id`) REFERENCES `routines`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`person_id`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
INSERT INTO `__new_tasks`("id", "kind", "routine_id", "person_id", "subject_type", "subject_id", "status", "where", "result", "error", "claimed_by", "claimed_at", "created_at", "updated_at") SELECT t."id", 'routine', t."routine_id", t."person_id", CASE WHEN t."message_id" IS NULL THEN NULL ELSE 'message' END, t."message_id", t."status", COALESCE((SELECT r."where" FROM `routines` r WHERE r."id" = t."routine_id"), 'server'), t."result", t."error", t."claimed_by", t."claimed_at", t."created_at", t."updated_at" FROM `tasks` t;--> statement-breakpoint
DROP TABLE `tasks`;--> statement-breakpoint
ALTER TABLE `__new_tasks` RENAME TO `tasks`;--> statement-breakpoint
PRAGMA foreign_keys=ON;--> statement-breakpoint
CREATE INDEX `tasks_person_status` ON `tasks` (`person_id`,`status`);--> statement-breakpoint
CREATE INDEX `tasks_status` ON `tasks` (`status`);--> statement-breakpoint
CREATE INDEX `tasks_subject` ON `tasks` (`subject_type`,`subject_id`);--> statement-breakpoint
ALTER TABLE `api_keys` ADD `restrictions` text DEFAULT '{}' NOT NULL;--> statement-breakpoint
UPDATE `api_keys` SET `restrictions` = json_object('mailboxes', json(`mailbox_ids`)) WHERE `mailbox_ids` IS NOT NULL;--> statement-breakpoint
ALTER TABLE `api_keys` DROP COLUMN `mailbox_ids`;--> statement-breakpoint
ALTER TABLE `people` ADD `admin` integer DEFAULT true NOT NULL;--> statement-breakpoint
ALTER TABLE `people` ADD `settings` text DEFAULT '{}' NOT NULL;--> statement-breakpoint
UPDATE `people` SET `settings` = json_object('language', `language`) WHERE `language` IS NOT NULL;--> statement-breakpoint
ALTER TABLE `people` DROP COLUMN `language`;