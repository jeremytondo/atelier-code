CREATE TABLE `workspaces` (
	`id` text PRIMARY KEY NOT NULL,
	`workspace_path` text NOT NULL,
	`created_at` text NOT NULL,
	`last_opened_at` text NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `workspaces_workspace_path_unique` ON `workspaces` (`workspace_path`);