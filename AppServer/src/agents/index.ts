import { createLifecyclePlaceholder, type LifecycleComponent } from "@/core/shared";

export const createAgentsFeaturePlaceholder = (): LifecycleComponent =>
  createLifecyclePlaceholder("feature.agents");
