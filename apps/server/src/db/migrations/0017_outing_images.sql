ALTER TABLE `outings` ADD `image_type` text;--> statement-breakpoint
ALTER TABLE `outings` ADD `image_source` text;--> statement-breakpoint
ALTER TABLE `outings` ADD `image_at` integer;--> statement-breakpoint
ALTER TABLE `outings` ADD `image_off` integer DEFAULT false NOT NULL;