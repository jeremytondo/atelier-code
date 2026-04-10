import { createLifecyclePlaceholder, type LifecycleComponent } from "@/core/shared";

export const createProtocolBootstrapPlaceholder = (): LifecycleComponent =>
  createLifecyclePlaceholder("core.protocol");
