CREATE TABLE `runners` (
	`id` text PRIMARY KEY NOT NULL,
	`key_id` text,
	`person_id` text,
	`name` text NOT NULL,
	`queues` text NOT NULL,
	`agents` text NOT NULL,
	`models` text NOT NULL,
	`kinds` text NOT NULL,
	`concurrency` integer DEFAULT 1 NOT NULL,
	`paused` integer DEFAULT false NOT NULL,
	`last_seen_at` integer,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	FOREIGN KEY (`key_id`) REFERENCES `api_keys`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`person_id`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `runners_key_name` ON `runners` (`key_id`,`name`);--> statement-breakpoint
CREATE TABLE `message_facts` (
	`message_id` text PRIMARY KEY NOT NULL,
	`person_id` text NOT NULL,
	`rules_version` integer NOT NULL,
	`sensitive` integer NOT NULL,
	`sensitive_kinds` text NOT NULL,
	`rule_category` text,
	`category` text,
	`priority` text,
	`summary` text,
	`people` text NOT NULL,
	`organisations` text NOT NULL,
	`amounts` text NOT NULL,
	`dates` text NOT NULL,
	`keywords` text NOT NULL,
	`source` text NOT NULL,
	`template_key` text,
	`template_id` text,
	`model` text,
	`model_at` integer,
	`model_attempts` integer DEFAULT 0 NOT NULL,
	`model_error` text,
	`indexed_at` integer NOT NULL,
	FOREIGN KEY (`message_id`) REFERENCES `messages`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`person_id`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `message_facts_person_model` ON `message_facts` (`person_id`,`model_at`);--> statement-breakpoint
CREATE INDEX `message_facts_person_template` ON `message_facts` (`person_id`,`template_key`);--> statement-breakpoint
CREATE TABLE `message_templates` (
	`id` text PRIMARY KEY NOT NULL,
	`person_id` text NOT NULL,
	`key` text NOT NULL,
	`members` integer NOT NULL,
	`category` text,
	`priority` text,
	`summary` text,
	`organisation` text,
	`keywords` text,
	`model` text,
	`facts_at` integer,
	`attempts` integer DEFAULT 0 NOT NULL,
	`created_at` integer DEFAULT (unixepoch() * 1000) NOT NULL,
	FOREIGN KEY (`person_id`) REFERENCES `people`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE UNIQUE INDEX `message_templates_person_key` ON `message_templates` (`person_id`,`key`);--> statement-breakpoint
DROP INDEX `tasks_status`;--> statement-breakpoint
ALTER TABLE `tasks` ADD `queue` text DEFAULT 'cloud' NOT NULL;--> statement-breakpoint
ALTER TABLE `tasks` ADD `priority` integer DEFAULT 1 NOT NULL;--> statement-breakpoint
ALTER TABLE `tasks` ADD `model` text;--> statement-breakpoint
ALTER TABLE `tasks` ADD `runner_id` text REFERENCES runners(id) ON DELETE set null;--> statement-breakpoint
CREATE INDEX `tasks_status` ON `tasks` (`status`,`queue`,`priority`);--> statement-breakpoint
ALTER TABLE `api_keys` ADD `facts_only` integer DEFAULT false NOT NULL;