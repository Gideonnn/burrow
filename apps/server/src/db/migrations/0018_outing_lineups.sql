CREATE TABLE `outing_lineups` (
	`outing_id` text PRIMARY KEY NOT NULL,
	`status` text NOT NULL,
	`artists` text DEFAULT '[]' NOT NULL,
	`complete` integer DEFAULT false NOT NULL,
	`note` text,
	`error` text,
	`sources` text DEFAULT '[]' NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`outing_id`) REFERENCES `outings`(`id`) ON UPDATE no action ON DELETE cascade
);
