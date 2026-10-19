CREATE TABLE `messages` (
	`id` text PRIMARY KEY NOT NULL,
	`mailbox_id` text NOT NULL,
	`provider_id` text NOT NULL,
	`thread_id` text,
	`from` text NOT NULL,
	`to` text NOT NULL,
	`cc` text NOT NULL,
	`subject` text NOT NULL,
	`snippet` text NOT NULL,
	`body_text` text,
	`body_html` text,
	`received_at` integer NOT NULL,
	`folder` text NOT NULL,
	`unread` integer NOT NULL,
	`flagged` integer NOT NULL,
	`labels` text NOT NULL,
	`has_attachments` integer NOT NULL,
	`headers` text NOT NULL,
	`triaged_at` integer,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	FOREIGN KEY (`mailbox_id`) REFERENCES `mailboxes`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `messages_mailbox_provider` ON `messages` (`mailbox_id`,`provider_id`);--> statement-breakpoint
CREATE INDEX `messages_mailbox_folder_received` ON `messages` (`mailbox_id`,`folder`,`received_at`);