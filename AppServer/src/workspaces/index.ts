import { createLifecyclePlaceholder, type LifecycleComponent } from "@/core/shared";

export const createWorkspacesFeaturePlaceholder = (): LifecycleComponent =>
  createLifecyclePlaceholder("feature.workspaces");
