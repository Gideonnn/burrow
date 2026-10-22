CREATE TABLE `outing_messages` (
	`outing_id` text NOT NULL,
	`message_id` text NOT NULL,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	FOREIGN KEY (`outing_id`) REFERENCES `outings`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`message_id`) REFERENCES `messages`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `outing_messages_pair` ON `outing_messages` (`outing_id`,`message_id`);--> statement-breakpoint
CREATE INDEX `outing_messages_message` ON `outing_messages` (`message_id`);--> statement-breakpoint
CREATE TABLE `outing_tasks` (
	`id` text PRIMARY KEY NOT NULL,
	`outing_id` text NOT NULL,
	`kind` text NOT NULL,
	`title` text NOT NULL,
	`due_at` integer,
	`assignee_id` text,
	`done_at` integer,
	`done_by` text,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	FOREIGN KEY (`outing_id`) REFERENCES `outings`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`assignee_id`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`done_by`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE TABLE `outing_tickets` (
	`id` text PRIMARY KEY NOT NULL,
	`outing_id` text NOT NULL,
	`name` text NOT NULL,
	`content_type` text NOT NULL,
	`size` integer NOT NULL,
	`file` text NOT NULL,
	`holder` text,
	`personalised` integer DEFAULT false NOT NULL,
	`message_id` text,
	`added_by` text NOT NULL,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	FOREIGN KEY (`outing_id`) REFERENCES `outings`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`message_id`) REFERENCES `messages`(`id`) ON UPDATE no action ON DELETE set null,
	FOREIGN KEY (`added_by`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE TABLE `outings` (
	`id` text PRIMARY KEY NOT NULL,
	`title` text NOT NULL,
	`kind` text,
	`starts_at` integer NOT NULL,
	`ends_at` integer,
	`doors_at` integer,
	`all_day` integer DEFAULT false NOT NULL,
	`venue` text,
	`address` text,
	`organiser` text,
	`vendor` text,
	`order_number` text,
	`url` text,
	`notes` text DEFAULT '' NOT NULL,
	`aliases` text DEFAULT '[]' NOT NULL,
	`search_text` text DEFAULT '' NOT NULL,
	`calendar_event_id` text,
	`in_calendar` integer DEFAULT false NOT NULL,
	`created_by` text NOT NULL,
	`updated_by` text NOT NULL,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`created_by`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE no action,
	FOREIGN KEY (`updated_by`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `outings_starts` ON `outings` (`starts_at`);