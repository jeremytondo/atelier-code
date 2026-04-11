import type { AgentRegistry } from "@/agents/registry";
import type { Logger } from "@/app/logger";
import type { ThreadsStore } from "@/threads/store";
import type { WorkspacePathNormalizer } from "@/workspaces/path";

export type ThreadMethodDependencies = Readonly<{
  logger: Logger;
  registry: AgentRegistry;
  store: ThreadsStore;
  now: () => string;
  normalizePath: WorkspacePathNormalizer;
}>;
