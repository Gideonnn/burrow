ALTER TABLE `people` ADD `email` text;--> statement-breakpoint
CREATE UNIQUE INDEX `people_email_unique` ON `people` (`email`);