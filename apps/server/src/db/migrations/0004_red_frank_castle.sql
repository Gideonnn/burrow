CREATE TABLE `message_insights` (
	`message_id` text PRIMARY KEY NOT NULL,
	`bot` text NOT NULL,
	`summary` text,
	`replies` text NOT NULL,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	FOREIGN KEY (`message_id`) REFERENCES `messages`(`id`) ON UPDATE no action ON DELETE cascade
);
