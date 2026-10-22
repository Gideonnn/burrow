CREATE TABLE `pensieve_labels` (
	`id` text PRIMARY KEY NOT NULL,
	`person_id` text NOT NULL,
	`name` text NOT NULL,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	FOREIGN KEY (`person_id`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `pensieve_labels_person_name` ON `pensieve_labels` (`person_id`,lower("name"));--> statement-breakpoint
CREATE TABLE `recording_labels` (
	`recording_id` text NOT NULL,
	`label_id` text NOT NULL,
	PRIMARY KEY(`recording_id`, `label_id`),
	FOREIGN KEY (`recording_id`) REFERENCES `recordings`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`label_id`) REFERENCES `pensieve_labels`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `recording_labels_label` ON `recording_labels` (`label_id`);--> statement-breakpoint
ALTER TABLE `recordings` ADD `kind` text DEFAULT 'call' NOT NULL;--> statement-breakpoint
ALTER TABLE `recordings` ADD `transcribe` integer DEFAULT true NOT NULL;--> statement-breakpoint
ALTER TABLE `recordings` ADD `segments` text;--> statement-breakpoint
ALTER TABLE `recordings` ADD `marks` text DEFAULT '[]' NOT NULL;