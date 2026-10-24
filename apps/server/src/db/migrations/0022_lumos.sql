CREATE TABLE `lumos_changes` (
	`id` text PRIMARY KEY NOT NULL,
	`person_id` text NOT NULL,
	`effects` text NOT NULL,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	`undone_at` integer,
	FOREIGN KEY (`person_id`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `lumos_list_items` (
	`id` text PRIMARY KEY NOT NULL,
	`owner_id` text,
	`media_type` text NOT NULL,
	`tmdb_id` integer NOT NULL,
	`origin` text NOT NULL,
	`seasons` text,
	`title` text NOT NULL,
	`year` integer,
	`poster` text,
	`added_by` text NOT NULL,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	`removed_at` integer,
	FOREIGN KEY (`owner_id`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`added_by`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `lumos_list_items_personal` ON `lumos_list_items` (`owner_id`,`media_type`,`tmdb_id`,`origin`) WHERE "lumos_list_items"."owner_id" is not null and "lumos_list_items"."removed_at" is null;--> statement-breakpoint
CREATE UNIQUE INDEX `lumos_list_items_shared` ON `lumos_list_items` (`media_type`,`tmdb_id`,`origin`) WHERE "lumos_list_items"."owner_id" is null and "lumos_list_items"."removed_at" is null;--> statement-breakpoint
CREATE TABLE `lumos_verdicts` (
	`id` text PRIMARY KEY NOT NULL,
	`person_id` text,
	`by_id` text NOT NULL,
	`media_type` text NOT NULL,
	`tmdb_id` integer NOT NULL,
	`origin` text NOT NULL,
	`kind` text NOT NULL,
	`reason` text,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	`undone_at` integer,
	FOREIGN KEY (`person_id`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`by_id`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `lumos_verdicts_title` ON `lumos_verdicts` (`media_type`,`tmdb_id`,`origin`);