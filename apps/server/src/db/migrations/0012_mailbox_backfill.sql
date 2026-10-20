ALTER TABLE `mailboxes` ADD `backfill_cursor` text;--> statement-breakpoint
ALTER TABLE `mailboxes` ADD `backfilled_at` integer;