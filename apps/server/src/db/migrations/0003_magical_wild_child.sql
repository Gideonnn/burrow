CREATE TABLE `drafts` (
	`id` text PRIMARY KEY NOT NULL,
	`mailbox_id` text NOT NULL,
	`created_by` text NOT NULL,
	`in_reply_to` text,
	`to` text NOT NULL,
	`cc` text NOT NULL,
	`subject` text NOT NULL,
	`body` text NOT NULL,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	FOREIGN KEY (`mailbox_id`) REFERENCES `mailboxes`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`in_reply_to`) REFERENCES `messages`(`id`) ON UPDATE no action ON DELETE set null
);
