CREATE TABLE `recordings` (
	`id` text PRIMARY KEY NOT NULL,
	`owner_id` text NOT NULL,
	`title` text NOT NULL,
	`started_at` integer NOT NULL,
	`duration_seconds` real,
	`status` text NOT NULL,
	`error` text,
	`source` text NOT NULL,
	`original` text,
	`audio` text,
	`audio_bytes` integer,
	`transcript` text,
	`notes` text,
	`notes_markdown` text,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	`updated_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	FOREIGN KEY (`owner_id`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `recordings_owner_started` ON `recordings` (`owner_id`,`started_at`);