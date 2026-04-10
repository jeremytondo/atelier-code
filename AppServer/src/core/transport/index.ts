import { createLifecyclePlaceholder, type LifecycleComponent } from "@/core/shared";

export const createTransportBootstrapPlaceholder = (): LifecycleComponent =>
  createLifecyclePlaceholder("core.transport");
