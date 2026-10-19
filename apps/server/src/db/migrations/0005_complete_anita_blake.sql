CREATE TABLE `routines` (
	`id` text PRIMARY KEY NOT NULL,
	`person_id` text NOT NULL,
	`name` text NOT NULL,
	`trigger` text NOT NULL,
	`skill` text NOT NULL,
	`bot` text NOT NULL,
	`where` text NOT NULL,
	`fallback_after_hours` integer,
	`approval` integer NOT NULL,
	`enabled` integer NOT NULL,
	`last_run_at` integer,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	FOREIGN KEY (`person_id`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE TABLE `tasks` (
	`id` text PRIMARY KEY NOT NULL,
	`routine_id` text NOT NULL,
	`person_id` text NOT NULL,
	`message_id` text,
	`status` text NOT NULL,
	`result` text,
	`error` text,
	`claimed_by` text,
	`claimed_at` integer,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	`updated_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	FOREIGN KEY (`routine_id`) REFERENCES `routines`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`person_id`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`message_id`) REFERENCES `messages`(`id`) ON UPDATE no action ON DELETE set null
);
--> statement-breakpoint
CREATE INDEX `tasks_person_status` ON `tasks` (`person_id`,`status`);