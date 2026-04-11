CREATE TABLE `workspace_threads` (
	`workspace_id` text NOT NULL,
	`provider` text NOT NULL,
	`thread_id` text NOT NULL,
	`thread_workspace_path` text NOT NULL,
	`archived` integer NOT NULL,
	`first_seen_at` text NOT NULL,
	`last_seen_at` text NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `workspace_threads_workspace_provider_thread_unique` ON `workspace_threads` (`workspace_id`,`provider`,`thread_id`);