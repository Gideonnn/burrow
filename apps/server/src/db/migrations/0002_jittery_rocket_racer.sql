CREATE TABLE `instructions` (
	`person_id` text PRIMARY KEY NOT NULL,
	`text` text NOT NULL,
	FOREIGN KEY (`person_id`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE TABLE `learned_rules` (
	`id` text PRIMARY KEY NOT NULL,
	`person_id` text NOT NULL,
	`text` text NOT NULL,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	FOREIGN KEY (`person_id`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE TABLE `triage_log` (
	`id` text PRIMARY KEY NOT NULL,
	`message_id` text NOT NULL,
	`person_id` text NOT NULL,
	`bot` text NOT NULL,
	`action` text NOT NULL,
	`reason` text NOT NULL,
	`unsure` integer NOT NULL,
	`ops` text NOT NULL,
	`status` text NOT NULL,
	`reviewed_at` integer,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	FOREIGN KEY (`message_id`) REFERENCES `messages`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`person_id`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `triage_log_person_status` ON `triage_log` (`person_id`,`status`);--> statement-breakpoint
ALTER TABLE `messages` ADD `triage_attempts` integer DEFAULT 0 NOT NULL;