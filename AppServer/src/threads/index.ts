import { createLifecyclePlaceholder, type LifecycleComponent } from "@/core/shared";

export const createThreadsFeaturePlaceholder = (): LifecycleComponent =>
  createLifecyclePlaceholder("feature.threads");
