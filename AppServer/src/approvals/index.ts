import { createLifecyclePlaceholder, type LifecycleComponent } from "@/core/shared";

export const createApprovalsFeaturePlaceholder = (): LifecycleComponent =>
  createLifecyclePlaceholder("feature.approvals");
