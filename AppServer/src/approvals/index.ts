import { createLifecyclePlaceholder, type LifecycleComponent } from "@/core/shared";

export const createApprovalsModulePlaceholder = (): LifecycleComponent =>
  createLifecyclePlaceholder("module.approvals");
