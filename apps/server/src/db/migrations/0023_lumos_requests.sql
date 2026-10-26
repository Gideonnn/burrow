CREATE TABLE `lumos_requests` (
	`id` text PRIMARY KEY NOT NULL,
	`media_type` text NOT NULL,
	`tmdb_id` integer NOT NULL,
	`seasons` text,
	`status` text NOT NULL,
	`seerr_request_id` integer,
	`attempts` integer DEFAULT 0 NOT NULL,
	`last_error` text,
	`next_attempt_at` integer,
	`requested_by` text NOT NULL,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`requested_by`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `lumos_requests_title` ON `lumos_requests` (`media_type`,`tmdb_id`);