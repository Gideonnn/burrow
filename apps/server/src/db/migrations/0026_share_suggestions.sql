CREATE TABLE `share_senders` (
	`owner_id` text NOT NULL,
	`address` text NOT NULL,
	`shared` integer DEFAULT 0 NOT NULL,
	`dismissed` integer DEFAULT 0 NOT NULL,
	`always` integer DEFAULT false NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`owner_id`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `share_senders_owner_address` ON `share_senders` (`owner_id`,`address`);--> statement-breakpoint
CREATE TABLE `share_suggestions` (
	`message_id` text PRIMARY KEY NOT NULL,
	`owner_id` text NOT NULL,
	`suggested` integer DEFAULT false NOT NULL,
	`reason` text DEFAULT '' NOT NULL,
	`state` text,
	`model` text,
	`attempts` integer DEFAULT 0 NOT NULL,
	`error` text,
	`judged_at` integer,
	`decided_at` integer,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	FOREIGN KEY (`message_id`) REFERENCES `messages`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`owner_id`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `share_suggestions_owner_state` ON `share_suggestions` (`owner_id`,`state`);